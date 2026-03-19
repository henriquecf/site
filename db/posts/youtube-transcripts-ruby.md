The [RAG pipeline](/blog/rag-without-leaving-rails) searches through thousands of video transcripts. The [metadata extractor](/blog/llm-extraction-at-scale) processes video titles and descriptions. Both assume the data is already in the database. This post is about how it got there.

YouTube's Data API v3 doesn't expose captions for videos you don't own. There's a Captions endpoint, but it requires OAuth and only works if you're the video owner or have explicit permission. For a knowledge base built from public lecture videos across dozens of channels, that's a non-starter.

I tried three approaches before landing on one that works.

## The protobuf approach (broken)

Several Python libraries (notably `youtube-transcript-api`) used to fetch transcripts by sending protobuf-encoded requests directly to YouTube's internal endpoints. Some Ruby ports attempted the same thing: encode a specific protobuf payload with the video ID and language code, POST it to an undocumented endpoint, decode the protobuf response.

This worked for a while. Then YouTube changed something on their end and the protobuf schema shifted. Every implementation relying on it broke silently. No error messages, just empty responses or 400s. The Python library had to be completely rewritten. The Ruby ports were abandoned.

I spent a few hours trying to get this working before realizing the format had changed and nobody had reverse-engineered the new one for Ruby.

## Scraping the watch page (IP-locked)

The second attempt was more straightforward. Load the YouTube watch page, parse the embedded `ytInitialPlayerResponse` JSON, and extract the caption track URL from it. This JSON blob contains everything the player needs, including an array of available caption tracks with their download URLs.

It works perfectly in a browser. The problem is that the caption URLs embedded in the watch page response are tied to the IP address and session that requested the page. If you extract the URL and try to fetch it in a subsequent HTTP call, you get a 403. YouTube signs these URLs with some combination of IP, timestamp, and session tokens.

I tried extracting the URL and fetching it immediately in a single pipeline. Some worked, most didn't. The expiration window was too short and unreliable. This wasn't going to scale to thousands of videos.

## What actually works: InnerTube with an Android client

YouTube's web player communicates with a backend called InnerTube. The API is undocumented but well-understood from browser DevTools and mobile app reverse engineering. What made it click: the Android YouTube client gets different, more permissive caption URLs than the web client.

The approach has three steps:

1. Extract the InnerTube API key from any YouTube watch page
2. Call the InnerTube player endpoint pretending to be the Android app
3. Fetch the caption URL from the response and download the transcript

Step 1 is a regex against the watch page HTML:

```ruby
def fetch_api_key(video_id)
  uri = URI("https://www.youtube.com/watch?v=#{video_id}")
  http = build_http(uri)
  req = Net::HTTP::Get.new(uri.request_uri)
  req["User-Agent"] = "Mozilla/5.0"
  html = http.request(req).body

  match = html.match(/"INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)"/)
  raise TranscriptNotAvailable, "Could not extract API key" unless match

  match[1]
end
```

The `INNERTUBE_API_KEY` is not a personal API key. It's YouTube's own client key, embedded in every watch page. It doesn't change often and isn't tied to any account.

Step 2 is where the Android identity matters:

```ruby
INNERTUBE_CLIENT = { clientName: "ANDROID", clientVersion: "20.10.38" }.freeze
USER_AGENT = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

def fetch_caption_url(video_id, api_key, language)
  uri = URI("https://www.youtube.com/youtubei/v1/player?key=#{api_key}")
  http = build_http(uri)

  req = Net::HTTP::Post.new(uri.request_uri)
  req["Content-Type"] = "application/json"
  req["User-Agent"] = USER_AGENT
  req.body = { context: { client: INNERTUBE_CLIENT }, videoId: video_id }.to_json

  response = http.request(req)
  data = JSON.parse(response.body)
  tracks = data.dig("captions", "playerCaptionsTracklistRenderer", "captionTracks")
  raise TranscriptNotAvailable, "No caption tracks available" if tracks.blank?

  track = tracks.find { |t| t["languageCode"] == language } || tracks.first
  track["baseUrl"]
end
```

By sending `clientName: "ANDROID"` and a matching User-Agent, YouTube returns caption URLs that aren't IP-locked. They're stable, fetchable from any IP, and work for auto-generated captions on any public video. This is the same approach the rewritten Python `youtube-transcript-api` ended up using.

## Parsing srv3

YouTube serves captions in a format called srv3, an XML structure with timed segments:

```xml
<?xml version="1.0" encoding="utf-8" ?>
<timedtext format="3">
  <body>
    <p t="1000" d="5000">
      <s ac="0">Boa</s>
      <s t="280" ac="0"> noite,</s>
      <s t="720" ac="0"> queridos</s>
      <s t="1200" ac="0"> irmãos.</s>
    </p>
    <p t="6000" d="4000">
      <s ac="0">Sejam</s>
      <s t="400" ac="0"> todos</s>
      <s t="800" ac="0"> bem-vindos.</s>
    </p>
  </body>
</timedtext>
```

Each `<p>` element is a caption segment with `t` (start time in milliseconds) and `d` (duration in milliseconds). The `<s>` elements are individual words with their relative timing offsets. For transcript purposes, I only need the segment-level timing and the concatenated text:

```ruby
def parse_srv3(xml)
  doc = REXML::Document.new(xml)
  segments = []

  doc.elements.each("timedtext/body/p") do |p|
    start_ms = p.attributes["t"].to_i
    duration_ms = p.attributes["d"].to_i
    text = p.elements.collect("s") { |s| s.text.to_s }.join("").strip
    next if text.blank?

    segments << { text: text, start_ms: start_ms, end_ms: start_ms + duration_ms }
  end

  raise TranscriptNotAvailable, "No transcript segments found" if segments.empty?

  segments
end
```

This gives me an array of hashes like `{ text: "Boa noite, queridos irmãos.", start_ms: 1000, end_ms: 6000 }`. The millisecond-level timing carries through to the chunking pipeline, so when the RAG system retrieves a relevant chunk, it can link directly to the timestamp in the video.

## The complete client

The whole thing fits in a single file with no external dependencies beyond Ruby's standard library (`net/http`, `json`, `rexml`):

```ruby
require "net/http"
require "json"
require "rexml/document"

module YouTube
  class TranscriptClient
    class TranscriptNotAvailable < StandardError; end

    INNERTUBE_CLIENT = { clientName: "ANDROID", clientVersion: "20.10.38" }.freeze
    USER_AGENT = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    def fetch(video_id, language: "pt")
      api_key = fetch_api_key(video_id)
      caption_url = fetch_caption_url(video_id, api_key, language)
      xml = fetch_transcript_xml(caption_url)
      parse_srv3(xml)
    end

    private

    def fetch_api_key(video_id)
      uri = URI("https://www.youtube.com/watch?v=#{video_id}")
      http = build_http(uri)
      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = "Mozilla/5.0"
      html = http.request(req).body

      match = html.match(/"INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)"/)
      raise TranscriptNotAvailable, "Could not extract API key" unless match

      match[1]
    end

    def fetch_caption_url(video_id, api_key, language)
      uri = URI("https://www.youtube.com/youtubei/v1/player?key=#{api_key}")
      http = build_http(uri)

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["User-Agent"] = USER_AGENT
      req.body = { context: { client: INNERTUBE_CLIENT }, videoId: video_id }.to_json

      response = http.request(req)
      raise TranscriptNotAvailable, "InnerTube request failed" unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      tracks = data.dig("captions", "playerCaptionsTracklistRenderer", "captionTracks")
      raise TranscriptNotAvailable, "No caption tracks available" if tracks.blank?

      track = tracks.find { |t| t["languageCode"] == language } || tracks.first
      track["baseUrl"]
    end

    def fetch_transcript_xml(url)
      uri = URI(url)
      http = build_http(uri)
      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = USER_AGENT
      response = http.request(req)

      raise TranscriptNotAvailable, "Transcript fetch failed" unless response.is_a?(Net::HTTPSuccess)
      raise TranscriptNotAvailable, "Empty transcript response" if response.body.blank?

      response.body
    end

    def parse_srv3(xml)
      doc = REXML::Document.new(xml)
      segments = []

      doc.elements.each("timedtext/body/p") do |p|
        start_ms = p.attributes["t"].to_i
        duration_ms = p.attributes["d"].to_i
        text = p.elements.collect("s") { |s| s.text.to_s }.join("").strip
        next if text.blank?

        segments << { text: text, start_ms: start_ms, end_ms: start_ms + duration_ms }
      end

      raise TranscriptNotAvailable, "No transcript segments found" if segments.empty?

      segments
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 10
      http
    end
  end
end
```

The `fetch` method is the public interface. Pass a video ID, get back an array of timed transcript segments. Language defaults to Portuguese since that's what [Guia](https://guia.tv) needs, but it falls back to whatever caption track is available.

## Storing transcripts

Each video stores the transcript in two forms:

```ruby
def fetch_transcript!
  client = YouTube::TranscriptClient.new
  segments = client.fetch(video_id)
  update!(
    raw_transcript: segments,
    plain_transcript: segments.map { |s| s[:text] }.join(" ")
  )
end
```

`raw_transcript` is a JSONB column with the full array of segments and their timing data. This feeds the chunking pipeline that creates vector embeddings for RAG search. `plain_transcript` is concatenated text for full-text search and for quickly eyeballing whether a transcript makes sense.

Having both columns has a practical benefit: the plain text is fast to scan when debugging. If a transcript looks garbled, I can open the record and read it immediately without parsing JSON. The structured format is what the downstream pipeline actually consumes.

## Running it across thousands of videos

A single fetch takes about two seconds: one request for the watch page, one POST to InnerTube, one GET for the caption XML. The bottleneck is network latency, not processing. For batch runs, each video gets its own background job:

```ruby
class FetchTranscriptJob < ApplicationJob
  queue_as :default

  def perform(video)
    return unless video.youtube?
    return if video.raw_transcript.present?

    video.fetch_transcript!
  rescue YouTube::TranscriptClient::TranscriptNotAvailable => e
    Rails.logger.warn "Transcript not available for video #{video.video_id}: #{e.message}"
  end
end
```

Two guard clauses at the top: skip non-YouTube videos (the platform also has Vimeo content), and skip videos that already have transcripts. The `TranscriptNotAvailable` rescue catches videos with no captions at all. Livestreams, very old videos, and some unlisted content don't have auto-generated captions. These failures are expected and just log a warning.

For larger batch runs, a rake task handles the full pipeline with progress tracking:

```ruby
videos.find_each.with_index(1) do |video, i|
  print "[#{i}/#{total}] #{video.title[0..60]}... "

  if video.raw_transcript.blank?
    segments = client.fetch(video.video_id)
    video.update!(
      raw_transcript: segments,
      plain_transcript: segments.map { |s| s[:text] }.join(" ")
    )
  end

  processor.call(video)
  video.update!(archive_status: :archived)

  puts "OK (#{video.chunks_count} chunks)"
rescue YouTube::TranscriptClient::TranscriptNotAvailable => e
  puts "SKIP (#{e.message})"
rescue => e
  puts "FAIL (#{e.class}: #{e.message})"
end
```

This runs the full pipeline sequentially: fetch transcript, chunk it, generate embeddings, mark as archived. Slow but predictable. I run it locally against specific date ranges when new content gets added. The results get exported to compressed seed files and deployed to production, as covered in the [extraction post](/blog/llm-extraction-at-scale).

## What can break

YouTube changes their internals without notice. The InnerTube approach has been stable for months, but there's no guarantee. The Android client version string might eventually stop working, the API key extraction regex might need updating, or the caption URL format could change.

The client has no retry logic. If a fetch fails, it fails. For batch processing, the job layer handles retries via Solid Queue's built-in mechanism. For one-off fetches from the admin panel, you just click the button again. Adding automatic retries with exponential backoff would be more robust, but for a knowledge base that gets updated in batches, "run it again" has been enough.

Auto-generated captions aren't always accurate either. YouTube's speech recognition handles Portuguese reasonably well for clear lecture-style content, but it struggles with proper nouns, technical terminology, and speakers with regional accents. The RAG pipeline accounts for this by using semantic search (vector similarity) rather than exact keyword matching, which is more forgiving of transcription errors.

The whole setup is fragile in theory. Everything runs through YouTube's undocumented internal API using their own client key, which means they could shut it down at any point. In practice, it's held up for months and processed thousands of videos without issues. If it breaks, the fix will probably be another round of reverse engineering the new client version or endpoint format. That's the deal you make when the official API doesn't give you what you need.
