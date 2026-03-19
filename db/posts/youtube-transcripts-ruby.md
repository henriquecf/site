The [RAG pipeline](/blog/rag-without-leaving-rails) searches through thousands of video transcripts. The [metadata extractor](/blog/llm-extraction-at-scale) processes video titles and descriptions. Both assume the data is already in the database. This post is about how it got there.

YouTube's Data API v3 has a Captions endpoint, but it's scoped to videos you own. For a knowledge base of public lecture videos across dozens of channels, I needed the same caption text that's already visible to anyone watching the video, just in a programmatic format.

There's no official endpoint for that. Libraries like Python's `youtube-transcript-api` have solved this by using YouTube's internal player API directly. I needed the same thing in Ruby, and it took a few attempts to get there.

## The protobuf approach (broken)

Several Python libraries (notably `youtube-transcript-api`) used to fetch transcripts by sending protobuf-encoded requests directly to YouTube's internal endpoints. Some Ruby ports attempted the same thing: encode a specific protobuf payload with the video ID and language code, POST it to an internal endpoint, decode the protobuf response.

This worked for a while. Then YouTube changed something on their end and the protobuf schema shifted. Every implementation relying on it broke silently. No error messages, just empty responses or 400s. The Python library had to be completely rewritten. The Ruby ports were abandoned.

I spent a few hours trying to get this working before realizing the format had changed and nobody had updated the Ruby implementations.

## Parsing the watch page (session-bound URLs)

The second attempt was more straightforward. Load the YouTube watch page, parse the embedded `ytInitialPlayerResponse` JSON, and extract the caption track URL from it. This JSON blob contains everything the player needs, including an array of available caption tracks with their download URLs.

It works perfectly in a browser. The problem is that the caption URLs in the watch page response are session-bound. If you extract the URL and try to fetch it in a subsequent HTTP call, you get a 403. The URLs expire quickly and are tied to the original request context.

I tried extracting the URL and fetching it immediately in a single pipeline. Some worked, most didn't. The expiration window was too short and unreliable. This wasn't going to scale to thousands of videos.

## What actually works: InnerTube with an Android client

YouTube's web player communicates with a backend called InnerTube. This is the same API that the Python `youtube-transcript-api` library uses after its rewrite, and the approach the [Ruby Events](https://github.com/rubyevents) project uses for their transcript pipeline. It's well-documented across multiple open source projects and works reliably with the Android client configuration.

Three steps:

1. Extract the InnerTube API key from a YouTube watch page
2. Call the InnerTube player endpoint with the Android client context
3. Fetch the caption URL from the response

The `INNERTUBE_API_KEY` extracted in step 1 is not a personal API key. It's YouTube's own client key, embedded in every watch page. It doesn't change often and isn't tied to any account.

## The complete client

Here's the full implementation. It fits in a single file with no external dependencies beyond Ruby's standard library (`net/http`, `json`, `rexml`):

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

YouTube serves captions in a format called srv3. Each `<p>` element in the XML is a caption segment with `t` (start time in milliseconds) and `d` (duration in milliseconds). The `<s>` elements inside are individual words. The `parse_srv3` method concatenates them into segment-level text and preserves the timing, so the result is an array of hashes like `{ text: "Boa noite, queridos irmãos.", start_ms: 1000, end_ms: 6000 }`. That millisecond-level timing carries through to the chunking pipeline, so when the RAG system retrieves a relevant chunk, it can link directly to the timestamp in the video.

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

For larger batch runs, a rake task wraps the same logic with progress tracking and error counts, running the full pipeline sequentially: fetch transcript, chunk it, generate embeddings, mark as archived. Slow but predictable. I run it locally against specific date ranges when new content gets added, then export the results to compressed seed files for production, as covered in the [extraction post](/blog/llm-extraction-at-scale).

## What can break

YouTube changes their internals without notice. The InnerTube approach has been stable for months, but there's no guarantee. The Android client version string might eventually stop working, the API key extraction regex might need updating, or the caption URL format could change.

The client has no retry logic. If a fetch fails, it fails. For batch processing, the job layer handles retries via Solid Queue's built-in mechanism. For one-off fetches from the admin panel, you just click the button again. Adding automatic retries with exponential backoff would be more robust, but for a knowledge base that gets updated in batches, "run it again" has been enough.

Auto-generated captions aren't always accurate either. YouTube's speech recognition handles Portuguese reasonably well for clear lecture-style content, but it struggles with proper nouns, technical terminology, and speakers with regional accents. The RAG pipeline accounts for this by using semantic search (vector similarity) rather than exact keyword matching, which is more forgiving of transcription errors.

The InnerTube API isn't officially documented, so there's always a chance something changes. In practice, it's been stable for months and is the same approach used by widely adopted open source projects. If the client version or endpoint format changes, the fix is usually updating a version string or adjusting a URL. The Ruby Events project deals with the same maintenance burden for their conference video transcripts, so there's a community keeping an eye on it.
