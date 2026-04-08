I run a knowledge base of spiritist YouTube videos at [guia.espirita.club](https://guia.espirita.club). The app aggregates content from dozens of channels and currently has over 40,000 videos. Each video needs structured metadata: who's speaking, what topics it covers. That's how users browse by speaker, filter by theme, and find related content.

YouTube's API doesn't give you any of this. The information lives in video titles and descriptions, written by hundreds of different channel operators in inconsistent formats. "PALESTRA ESPIRITA - Claudia Piva" has the speaker in the title. Others bury it in the description as "Palestrante: Janice Leal". Some don't mention the speaker at all.

This is an LLM job. Read the title and description, extract speaker names and roles, classify into predefined themes. I needed to do it across the entire catalog, and I didn't want to pay for it.

## Starting with Groq's free tier

My first approach was Groq's free API with `gpt-oss-20b`. The free tier gives you 30 requests per minute, 1,000 per day, 8K tokens per minute, and 200K tokens per day.

For the initial batch of 8,000 videos, this worked fine. Each extraction takes a few hundred input tokens (title + description) and returns a small JSON response with speaker names, roles (speaker, interviewer, moderator, medium), and confidence levels. The prompt also handles Portuguese role conventions, where "Palestrante" and "Expositor" both mean speaker, and "Médium" means someone channeling a spiritual entity rather than presenting their own material.

At 30 RPM with a 2-second sleep between requests, I could process about 30 videos per minute. The initial catalog took a few days to get through.

The problem showed up when the catalog grew. I added more channels and the total hit 40K. Daily imports bring in 50-100 new videos, well within the free tier's limits. But the backlog of unprocessed videos from newly added channels was thousands deep, and at 1,000 requests per day, clearing it would take weeks.

I also tried `llama-3.1-8b-instant`, which has a much more generous free tier at 14,400 RPD. But the quality drop was real. It hallucinated speaker names on ambiguous videos and missed topics on devotional content that didn't have an explicit theme in the title. For a catalog where accuracy matters more than speed, the cheaper model wasn't worth it.

I did the math on Groq's paid tier: about $4.83 total for the entire backlog (54M input tokens at $0.075/M, 2.6M output tokens at $0.30/M). Cheap, but the free tier already covered daily processing, and I had a server with Ollama running for embeddings. Why not run the extraction locally?

## YouTube blocks your server

Before the local model story, there's an architectural constraint that shaped everything.

The app also needs video transcripts for topic classification, which requires understanding what the video is actually about, not just the title. YouTube's transcript endpoint returns CAPTCHA pages or `FAILED_PRECONDITION` errors from cloud IPs. I tried watch page scraping and the protobuf `get_transcript` endpoint. Same result from any VPS IP.

The solution was an internal API. The production server exposes authenticated endpoints:

```
GET  /internal_api/metadata_extractions/next
POST /internal_api/metadata_extractions
```

The first returns the next video that needs processing. The second accepts the result and persists it, returning the next pending video in the same response so the client doesn't need a separate request.

A rake task on my Mac loops continuously: fetch the next pending video, run the LLM extraction, POST the result back, repeat until nothing's left. A launchd plist runs this hourly with a PID lockfile to prevent overlapping runs.

```bash
# Simplified version of the local processing loop
while true; do
  response=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "$SERVER/internal_api/metadata_extractions/next")

  [ "$response" = "null" ] && break

  video_id=$(echo "$response" | jq -r '.id')
  title=$(echo "$response" | jq -r '.title')
  description=$(echo "$response" | jq -r '.description')

  result=$(ollama_extract "$title" "$description")

  curl -s -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"video_id\": $video_id, \"extraction\": $result}" \
    "$SERVER/internal_api/metadata_extractions"
done
```

This pattern turned out to be the best part of the whole architecture. I use it for transcripts, embeddings, and metadata extraction. The server knows what needs processing. Any machine with API access and a local model can work through the queue. If I got a machine with a faster GPU, I'd point it at the same endpoints and processing would speed up with zero server-side changes.

The launchd plists on my Mac run hourly. Each one has a PID lockfile so it skips if the previous run is still going. Logs rotate automatically, keeping the last five runs. It's not glamorous infrastructure, but it's been running unattended for weeks.

## The rate limit cascade

While still on Groq, I hit a bug worth mentioning because it's a classic Ruby trap.

My extraction job had this rescue chain:

```ruby
rescue LlmError, StandardError => e
  video.update!(processing_status: :failed)
```

`RateLimitError` inherits from `StandardError`. When Groq returned a 429, the error was caught by `StandardError` before it could propagate to the job-level retry handler. Videos got marked as permanently failed instead of retried.

A separate hourly job scanned for failed videos and re-enqueued them. Within days, Solid Queue had 18,000+ duplicate extraction jobs, all hitting Groq, all getting rate limited, all getting marked as failed, all getting re-enqueued again.

The fix was ordering the rescue clauses correctly and adding `on_conflict: :discard` to prevent duplicate jobs. The real signal was noticing a queue that should have had dozens of jobs somehow had 18,000.

## Going local

The tipping point came when Groq's free tier was so throttled that zero extractions completed in a day. The daily cap hit early, every subsequent request got a 20-minute `retry-after`, and I was maintaining a pipeline that processed nothing.

I already had Ollama on the production server for embeddings, but the server only has 4GB of VRAM. The embedding model (bge-m3) takes 1.2GB and stays resident, leaving about 2.8GB for a chat model. Most 4B parameter models hover around 2.5-3.5GB, so it's tight.

I set up a benchmark: 25 test scenarios covering the hardest edge cases. The trickiest one was the spirit author problem. In spiritist content, "Emmanuel através de Chico Xavier" means Emmanuel is a spirit entity communicating through the medium Chico Xavier. Emmanuel should be tagged as the author, not the speaker. Chico Xavier is the medium, not the presenter either. The actual speaker might be someone else entirely, reading the dictated text aloud. Early prompts got this wrong constantly. The LLM saw the names in the description and listed them all as speakers.

Other edge cases: videos with multiple speakers on a panel, devotional content with no speakers at all (just music or prayers), and Portuguese role names where "Palestrante," "Expositor," and "Orador" all mean speaker but "Médium" does not.

Six models, same prompt, same 25 test cases:

| Model | Size | Quality | Speed | Verdict |
|-------|------|---------|-------|---------|
| gemma3:4b | 3.3GB | Perfect speakers, clean topics | 1-5s | Best overall |
| ministral-3 | 6.0GB | Perfect | 3-8s | Too large for my server |
| qwen3.5:2b | 2.7GB | Good speakers, excessive topics | 2-3s | Usable |
| llama3.2:3b | 2.0GB | Hallucinated speakers | 1-11s | No |
| qwen3.5:4b | 3.4GB | Good, but broken JSON output | 4-6s | Unreliable |
| gemma3:270m | 291MB | Missing roles, empty topics | <1s | Too small |

llama3.2:3b was the worst offender for hallucination. Given a video titled "Oração para o lar" (Prayer for the home), it invented a speaker name that appeared nowhere in the title or description. qwen3.5:4b produced good extractions but wrapped its JSON output in markdown code fences despite being told not to, which broke parsing on about one in five responses. qwen3.5:2b was usable for speakers but tagged every video with a dozen topics when most videos have two or three.

gemma3:4b won clearly. It fit in memory alongside the embedding model, handled the spirit author distinction correctly after prompt tuning, and produced valid JSON consistently. I ran the initial extraction on the server and cleared the backlog in a few days.

## The thinking mode trap

When I later upgraded to newer models, I tried qwen3:4b and something was off. Extractions that should take a second were taking 50-100 seconds.

The results were correct. The model was just absurdly slow for a 4B parameter model on decent hardware.

Qwen3 enables thinking mode by default. The model generates hundreds of reasoning tokens wrapped in `<think>` tags before producing the actual JSON output. For a structured extraction task where the answer is "read the title, return the speaker name," the model was spending 95% of its compute reasoning about how to extract a name from a string.

Disabling it through Ollama's API (`think: false`) dropped inference from 50-100 seconds to under one second. Same model, same prompt, same output quality.

```ruby
# Ollama native API - disable thinking for structured extraction
response = client.chat(
  model: "qwen3:4b",
  messages: [{ role: "user", content: prompt }],
  format: "json",
  think: false  # This is the difference between 100s and <1s
)
```

This isn't documented prominently. If you're running Qwen3 on Ollama for structured extraction and it's inexplicably slow, check if thinking mode is on. For tasks where the model needs to reason through a complex problem, thinking mode helps. For "read this text and return a JSON with names," it's pure overhead.

## JSON reliability with small models

One thing I didn't expect: small models are unreliable JSON producers, even with Ollama's `format: "json"` constraint.

gemma4:e4b (Gemma 4's efficient 4B variant) produces structurally invalid JSON maybe one in ten requests. Trailing commas before closing braces. `]` where `}` should be. Markdown code fences wrapping the response. The format constraint helps but doesn't eliminate the problem entirely.

I added a sanitization step:

```ruby
def sanitize_json(text)
  text = text.gsub(/```json\s*/, "").gsub(/```\s*$/, "")
  text = text.gsub(/,(\s*[}\]])/, '\1')
  text = text.gsub(/\](\s*)$/, '}\1') if text.count("{") > text.count("}")
  text
end
```

It catches the three most common failures: markdown wrapping, trailing commas, and mismatched braces. Turned a 90% success rate into something close to 99%. The alternative is a bigger model that produces clean JSON, but that means cloud API calls and rate limits again.

## Where it landed

The system settled into a clear split based on task complexity:

**Speaker extraction** (title + description only): runs a 4B model locally on my Mac. The input is short, the task is straightforward, small models handle it fine.

**Topic classification** (from full transcript, 32 themes): needs a larger model. Small models produce too many JSON errors with long transcripts and don't classify accurately across that many categories. This goes through a cloud API.

**Daily processing**: 50-100 new videos per day, handled automatically by a launchd cron job on my Mac hitting the internal API endpoints.

**Backfill**: same rake task, just runs longer. I processed the full 40K catalog from my laptop over a few days.

Total cost: $0. The Mac is on anyway. Ollama is free. The internal API pattern means any machine can chip away at the queue.

## What I learned about small models

A few things surprised me working with 4B models at this scale.

First, the known speakers list. I initially passed all 289 known speakers to the model in the prompt so it could match extracted names against them. On some videos, the 4B model just dumped the entire list back as the extraction result, returning 118 speakers for a single talk. It treated the reference list as the answer rather than using it for matching. Removing the list from the prompt and doing the matching in Ruby afterward was both simpler and more reliable. The DB query to find a fuzzy match against known speakers takes microseconds. The model doesn't need to do it.

Second, context length matters more than parameter count for topic classification. Speaker extraction works fine with small models because the input is short (title + description, rarely more than 500 tokens). Topic classification needs the full transcript, which can be thousands of tokens. The small models' JSON reliability degrades noticeably with longer inputs. They lose track of the output structure partway through and produce malformed responses. For classification I had to move to a larger model regardless of whether it ran locally or in the cloud.

Third, VRAM management on a constrained server is its own puzzle. Ollama loads models on demand and evicts them when memory is tight. With only 4GB total, loading a 3.3GB chat model alongside a 1.2GB embedding model left almost no headroom. I ended up running the embedding model with `keep_alive: -1` (permanently resident) and letting the chat model load and unload per batch. On my Mac with more memory, this isn't an issue. On the server, it meant I couldn't run both tasks concurrently.

Eventually I removed Ollama from the production server entirely. Everything AI-related goes through cloud APIs for the web-facing features (Groq for the chat agent), and all batch processing runs on my Mac through the internal API. The server just serves the app. The Mac does the thinking.
