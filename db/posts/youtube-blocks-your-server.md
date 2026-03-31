In the [previous post](/blog/youtube-transcripts-ruby), I built a Ruby client that fetches YouTube transcripts via the InnerTube player API. Clean implementation, no external dependencies, works perfectly. The next step was obvious: run it across 6,000 videos on the server and populate the knowledge base.

That step lasted about 15 seconds.

## The bulk run

[Guia](https://guia.espirita.club) is a spiritist content platform with a RAG-powered chat. The chat searches through video transcripts, so every public video needs its captions pulled, chunked, and embedded. I had around 6,000 videos queued for transcript fetching, each one its own background job via Solid Queue.

I deployed, the jobs started processing, and the queue drained fast. Within 15 seconds the count dropped from 5,853 to 4,371. Most of those were returning "no captions available" immediately, which is expected for livestreams and older content. But the ones that should have returned transcripts were also failing. Every single one.

I SSH'd into the server and ran a quick curl against a video I knew had captions:

```bash
curl -sI "https://www.youtube.com/watch?v=some_video_id"
```

302 redirect to `google.com/sorry/index`. YouTube's CAPTCHA page. The server's IP was banned.

## Trying the back door

The `TranscriptClient` fetches transcripts in three steps: scrape the watch page for an API key, call InnerTube for a caption URL, download the XML. The ban hit at step one because the watch page itself was returning the CAPTCHA redirect.

I figured the fix might be to skip the watch page entirely. The [Ruby Events](https://github.com/rubyevents) project uses a different approach: POST directly to YouTube's `get_transcript` endpoint with protobuf-encoded parameters. No watch page scrape, no API key extraction. I matched their exact request format, including the protobuf encoding and client context:

```ruby
uri = URI("https://www.youtube.com/youtubei/v1/get_transcript")
req = Net::HTTP::Post.new(uri.request_uri)
req["Content-Type"] = "application/json"
req.body = {
  context: { client: { clientName: "WEB", clientVersion: "2.20250101" } },
  params: Base64.strict_encode64(protobuf_payload)
}.to_json
```

400 error. `FAILED_PRECONDITION`.

I tried adding cookies from a fresh youtube.com visit. Added more headers. Swapped client versions. Every combination returned the same thing. The issue wasn't the endpoint or the request format. YouTube blocks server IPs from all transcript methods. You can't work around it by changing which internal API you call.

This is well-documented in open source issue trackers once you know what to search for. The Python `youtube-transcript-api` has [open issues](https://github.com/jdepoix/youtube-transcript-api/issues/303) about cloud IPs getting blocked. ReVanced has similar reports. The consensus is that YouTube fingerprints requests by source IP range and rejects anything that looks like a datacenter.

## The data damage

While I was debugging the IP ban, I noticed something worse. The `FetchTranscriptJob` had a simple rescue clause:

```ruby
rescue YouTube::TranscriptClient::TranscriptNotAvailable
  video.update!(status: :no_transcript)
```

When the watch page returned a CAPTCHA redirect instead of HTML, the client couldn't extract the API key and raised `TranscriptNotAvailable`. Technically correct, from the exception's perspective, but semantically wrong. The video wasn't missing captions. The server was blocked. And the job had marked 7,500+ videos as permanently having no transcript, a status that the pipeline treats as final and never retries.

The fix was adding a separate exception class:

```ruby
class RateLimited < StandardError; end

def fetch_api_key(video_id)
  # ...
  response = http.request(req)

  if response.is_a?(Net::HTTPRedirection) &&
      response["location"]&.include?("google.com/sorry")
    raise RateLimited, "YouTube rate-limited this IP"
  end
  # ...
end
```

Then resetting all 7,625 wrongly-marked videos back to their previous state.

## Inverting the architecture

The server's IP is burned. Proxies are an option, but rotating residential proxies for 6,000 videos felt like building infrastructure to work around a problem that has a simpler solution: my laptop isn't blocked.

YouTube doesn't ban residential IPs from normal-volume transcript fetching. I'd been fetching transcripts locally during development without any issues. So instead of figuring out how to make the server fetch from YouTube, I made the server stop trying. The server would become an API that accepts transcripts, and my local machine would do the fetching.

The architecture is straightforward:

```
┌──────────────┐     GET /api/transcripts/next      ┌──────────────┐
│              │ ◄─────────────────────────────────── │              │
│    Server    │                                      │  Local Mac   │
│   (Kamal)    │     POST /api/transcripts            │  (launchd)   │
│              │ ◄─────────────────────────────────── │              │
└──────────────┘                                      └──────────────┘
                                                            │
                                                            ▼
                                                      ┌──────────────┐
                                                      │   YouTube    │
                                                      └──────────────┘
```

The server exposes two endpoints. `GET /api/transcripts/next` returns the next video that needs a transcript. `POST /api/transcripts` accepts the result and returns the next pending video in the same response. That second detail matters: combining "submit result" and "get next work item" into a single request cuts the round trips in half.

## The server side

The API uses bearer token auth with a token stored in Rails credentials:

```ruby
module Api
  class BaseController < ActionController::API
    before_action :authenticate

    private

    def authenticate
      token = request.headers["Authorization"]&.delete_prefix("Bearer ")
      expected = Rails.application.credentials.transcript_api_token

      unless token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
        head :unauthorized
      end
    end
  end
end
```

The transcripts controller handles both directions of the pipeline:

```ruby
module Api
  class TranscriptsController < BaseController
    def next_pending
      video = Video.where(status: :archive_approved)
                   .where(raw_transcript: nil)
                   .order(recorded_on: :desc)
                   .first

      if video
        render json: { id: video.id, video_id: video.video_id, title: video.title }
      else
        head :no_content
      end
    end

    def create
      video = Video.find(params[:id])

      if params[:no_transcript]
        video.update!(status: :no_transcript)
      else
        video.update!(
          raw_transcript: params[:segments],
          plain_transcript: params[:segments].map { |s| s[:text] }.join(" ")
        )
      end

      # Return next pending video in the same response
      next_video = Video.where(status: :archive_approved)
                        .where(raw_transcript: nil)
                        .where.not(id: video.id)
                        .order(recorded_on: :desc)
                        .first

      if next_video
        render json: { id: next_video.id, video_id: next_video.video_id, title: next_video.title }
      else
        head :no_content
      end
    end
  end
end
```

The server-side background jobs that used to fetch transcripts are neutered with an environment variable guard:

```ruby
class FetchTranscriptJob < ApplicationJob
  def perform(video)
    return unless ENV["FETCH_TRANSCRIPTS_ENABLED"] == "true"
    # ...
  end
end
```

That variable isn't set in `config/deploy.yml`, so the job is a no-op on the server. The job class still exists because other parts of the codebase reference it, but it never does anything in production.

## The local side

A rake task runs the fetch loop:

```ruby
# lib/tasks/transcripts.rake
namespace :transcripts do
  task fetch: :environment do
    lockfile = Rails.root.join("tmp/transcript_fetch.lock")
    lock_fh = File.open(lockfile, File::RDWR | File::CREAT)

    unless lock_fh.flock(File::LOCK_EX | File::LOCK_NB)
      puts "Another instance is running. Exiting."
      exit 0
    end

    lock_fh.truncate(0)
    lock_fh.write(Process.pid.to_s)
    lock_fh.flush

    api_url = ENV.fetch("TRANSCRIPT_API_URL", "https://guia.espirita.club")
    token = Rails.application.credentials.transcript_api_token
    client = YouTube::TranscriptClient.new
    fetched = 0
    no_transcript = 0

    # Get first video
    video = api_get("#{api_url}/api/transcripts/next", token)

    while video
      begin
        segments = client.fetch(video["video_id"])
        response = api_post("#{api_url}/api/transcripts", token, {
          id: video["id"], segments: segments
        })
        fetched += 1
      rescue YouTube::TranscriptClient::TranscriptNotAvailable
        response = api_post("#{api_url}/api/transcripts", token, {
          id: video["id"], no_transcript: true
        })
        no_transcript += 1
      rescue YouTube::TranscriptClient::RateLimited
        puts "Rate limited. Stopping."
        break
      end

      video = response # POST returns next video
    end

    puts "Done. Fetched: #{fetched}, No transcript: #{no_transcript}"
  end
end
```

The `flock` at the top is important. An earlier version used a PID file, which works fine until you `kill -9` the process and the stale PID file blocks all future runs. `flock` is a kernel-level lock that the OS releases when the process dies, regardless of how it dies. The file stays on disk but the lock is gone, so the next run acquires it cleanly.

The rate limiting strategy is deliberately simple: if YouTube returns a CAPTCHA redirect, stop. No delays between requests, no exponential backoff, no retries. The next hourly cron run picks up where this one left off. YouTube's ban seems to reset within an hour for residential IPs, so this approach naturally stays under whatever threshold triggers the block.

## Scheduling with launchd

On macOS, `launchd` is the right way to schedule recurring tasks. A plist in `~/Library/LaunchAgents/` handles the hourly runs:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.guia.transcript-fetch</string>
    <key>WorkingDirectory</key>
    <string>/Users/henrique/code/guia</string>
    <key>ProgramArguments</key>
    <array>
        <string>bin/rails</string>
        <string>transcripts:fetch</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>/Users/henrique/code/guia/log/transcripts/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/henrique/code/guia/log/transcripts/launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/Users/henrique/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
```

Install and start it:

```bash
cp config/launchd/com.guia.transcript-fetch.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.guia.transcript-fetch.plist
```

The PATH in the plist is critical. launchd runs with a minimal environment that doesn't include mise shims or Homebrew's bin directory. Without the explicit PATH, `bin/rails` can't find Ruby.

The same pattern handles embeddings. A second plist runs `bin/rails embeddings:generate` hourly, fetching transcript text from the server, running it through Ollama's bge-m3 locally, and posting the resulting vectors back. Local embedding generation runs about 10x faster than on the CPU-only production server, which was a nice side effect of the architectural inversion.

## The pattern

The interesting thing about this solution isn't the specific implementation. It's the inversion. The conventional architecture for data pipelines is: server runs jobs, server fetches external data, server processes it. When the external service blocks server IPs, the instinct is to fix the server: add proxies, rotate IPs, add delays.

The alternative is to ask who actually has access. My laptop fetches YouTube transcripts without issues. It's not a server. It's not in a datacenter IP range. YouTube doesn't care about it. So instead of making the server pretend to not be a server, I made it stop trying to be the fetcher entirely. The server became the API, and the machine with access became the worker.

This applies to any service that rate-limits or blocks datacenter IPs. Social media scrapers, search engine data, any third-party service that distinguishes between "real users" and "servers" by IP reputation. Instead of building increasingly complex server-side workarounds, consider whether you already have a machine that can do the fetching. A local dev machine, an office server on a residential connection, a Raspberry Pi on a home network. Make your production server the receiver, not the fetcher.

The first batch run from my laptop processed 10 transcripts in 32 seconds. The hourly cron chips away at the backlog steadily, processing over a thousand videos per run. No proxies, no IP rotation, no clever request timing. Just the right machine doing the fetching.
