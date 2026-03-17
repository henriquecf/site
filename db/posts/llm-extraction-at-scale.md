The [RAG pipeline I built for Guia](/blog/rag-without-leaving-rails) could search through 6,383 YouTube video transcripts by semantic similarity. But the search results weren't useful on their own. A chunk of transcript text and a video title, with no way to know who was speaking or what topic the lecture covered.

The metadata I needed was already in the videos. A title like "Estudo do Evangelho Segundo o Espiritismo com Haroldo Dutra Dias" tells you the speaker and the topic, but that information is locked in an unstructured string. I needed it extracted, normalized, and queryable.

So I pointed an LLM at each video's title, description, and channel name. One call took about 175 milliseconds. Getting it to work reliably across all 6,383 videos took considerably longer.

## Defining the output

RubyLLM has a schema DSL that maps to JSON Schema. You define a Ruby class, and the gem generates the schema sent to the LLM as the `response_format` parameter. The response is guaranteed to match your structure.

```ruby
class OutputSchema < RubyLLM::Schema
  array :speakers, description: "Speakers/participants in the video" do
    object do
      string :name, description: "Full name of the speaker"
      string :role, enum: %w[speaker interviewer moderator],
             description: "Role in the video"
      string :confidence, enum: %w[high medium low],
             description: "Extraction confidence level"
    end
  end

  array :topics, of: :string,
        description: "Topics from the provided list that match this video"
end
```

Two details in this schema saved me significant cleanup later: the `confidence` level lets the LLM express uncertainty instead of guessing, and constraining topics to a provided list prevents the model from inventing categories. More on both below.

## The prompt does the heavy lifting

The extraction model is small and fast (Groq's `gpt-oss-20b`), so the prompt needs to be explicit. The system prompt is in Portuguese, since all the content is Portuguese, and includes pattern-matching rules for extracting speaker roles from video descriptions:

- "Palestrante:" → speaker
- "Entrevistador:" → interviewer
- "Direção:" → moderator
- A name after "com" in the title is usually the speaker
- Abbreviations map to full topic names: "ESE" → "Evangelho Segundo o Espiritismo"

The prompt also receives two critical lists: every known speaker (with their alternative names) and every valid topic.

```ruby
def build_prompt(video)
  speakers_list = Speaker.ordered.map do |s|
    names = [s.name, *s.alternative_names].join(", ")
    "- #{names}"
  end

  <<~PROMPT
    Video: #{video.title}
    Canal: #{video.channel.name}
    Descrição: #{video.description}

    Palestrantes conhecidos:
    #{speakers_list.join("\n")}

    Tópicos disponíveis:
    #{Topic.ordered.pluck(:name).join(", ")}
  PROMPT
end
```

Passing the known speakers list was the single biggest quality improvement. Without it, the LLM extracted "Haroldo" from one video and "Haroldo Dutra Dias" from another, creating duplicates everywhere. With the list in context, it matches against existing names and returns consistent results.

## The Ollama detour

I started with Ollama running locally, the same setup from the [RAG post](/blog/rag-without-leaving-rails) where it handles embeddings. For metadata extraction, I pointed RubyLLM at the local instance and got results that looked reasonable at first.

The structured output wasn't actually structured. Ollama's OpenAI-compatible endpoint (`/v1/chat/completions`) silently ignores the `response_format` parameter. No error, no warning. It returns free-form text that sometimes happens to look like valid JSON and sometimes doesn't. RubyLLM routes through this endpoint, so my `OutputSchema` wasn't enforcing anything.

I spent a day debugging inconsistent results before realizing schema enforcement wasn't happening at all. Some videos extracted perfectly because the model happened to produce valid JSON. Others returned partial objects or hallucinated fields that didn't match the schema. The native Ollama API (`/api/chat`) does support structured output, but that's not the endpoint RubyLLM uses.

Switching to Groq fixed this immediately. Same RubyLLM code, same schema, same prompt. Groq actually enforces the JSON Schema, so every response matches `OutputSchema`. At about 175ms per call versus multiple seconds locally, batch processing became practical too.

## Speaker matching is the hard part

The first extraction run across all videos created over 400 speaker records. Only about 280 were actually unique. The rest were duplicates: accent variations ("Dircinéia" vs "Dircineia"), name fragments ("Haroldo" vs "Haroldo Dutra Dias"), title prefixes ("Prof. José" vs "José Carlos").

I added fuzzy matching to the Speaker model:

```ruby
class Speaker < ApplicationRecord
  def self.find_by_name_fuzzy(name)
    found = where("LOWER(name) = LOWER(?)", name).first
    return found if found

    found = where(
      "EXISTS (SELECT 1 FROM unnest(alternative_names) AS alt WHERE LOWER(alt) = LOWER(?))",
      name
    ).first
    return found if found

    where(
      "LOWER(name) LIKE LOWER(?) OR LOWER(?) LIKE '%' || LOWER(name) || '%'",
      "%#{name}%", name
    ).first
  end
end
```

The `alternative_names` column is a PostgreSQL text array. When I find duplicates, I merge them: keep one canonical record, move the variants into `alternative_names`, and re-run extraction. On subsequent runs, `find_by_name_fuzzy` matches against both the canonical name and all alternatives.

The confidence field from the schema turned out to be essential for data quality. When the LLM isn't sure about a speaker, it returns `confidence: "low"`. The extractor skips these:

```ruby
speakers_data.each do |entry|
  next if entry["confidence"] == "low"

  speaker = Speaker.find_by_name_fuzzy(entry["name"])
  speaker ||= Speaker.create!(name: entry["name"])

  video.video_speakers.create!(speaker: speaker, role: entry["role"])
end
```

Low-confidence entries still get stored in the raw `metadata_extraction` JSONB column on the video record. They're available for auditing, but they don't create associations that would pollute search results with uncertain data.

## Topics use the opposite approach

Instead of fuzzy matching and creating new records, the extractor only links topics that already exist:

```ruby
topics_data.each do |name|
  topic = Topic.where("LOWER(name) = LOWER(?)", name.strip).first
  next unless topic

  video.video_topics.create!(topic: topic)
end
```

There are 15 topics, seeded before extraction runs. The LLM receives the full list in the prompt and picks from it. If it returns something that doesn't match, the entry gets dropped.

Without this whitelist, the LLM generated dozens of variations: "Mediumship", "Mediunidade", "Studies on Mediumship", "Practical Mediumship." With it, everything maps to one of 15 canonical categories. The constraint works at two levels: the prompt tells the LLM which topics exist, and the code only links topics it finds in the database.

## One job per video

The batch architecture is straightforward. A bulk job enqueues individual extraction jobs:

```ruby
class ExtractAllVideoMetadataJob < ApplicationJob
  def perform(scope: :pending)
    videos = case scope.to_sym
    when :all then Video.visible
    else Video.visible.where(metadata_extracted_at: nil)
    end

    videos.find_each do |video|
      ExtractVideoMetadataJob.perform_later(video)
    end
  end
end
```

`find_each` loads videos in batches of 1,000 to avoid pulling everything into memory. Each job calls the extractor for a single video. Solid Queue manages concurrency, which naturally throttles API calls without explicit rate limiting.

The retry logic appends the error message to the prompt on the second attempt:

```ruby
def ask_llm(prompt, error_context: nil)
  if error_context
    prompt = "#{prompt}\n\n[Previous attempt failed: #{error_context}. Please try again carefully.]"
  end
  # LLM call...
end
```

On final failure (after one retry), the extractor stores empty arrays and sets `metadata_extracted_at` to the current time. Without that timestamp, a failed video would get re-enqueued on every bulk run, potentially thousands of times. Marking it as "extracted with empty results" breaks the loop.

The whole extraction is idempotent. Running it twice on the same video clears old associations and creates fresh ones, so re-running after a prompt fix or a speaker list update is safe.

## Getting extracted data to production

Extraction runs in development against a local database with all the transcripts loaded. Production doesn't have Groq access for batch extraction (only for the live chat agent). So I needed a way to ship the extracted metadata to production without re-running the LLM.

The solution is compressed seed files:

```ruby
# lib/tasks/videos.rake
task export_metadata_seeds: :environment do
  speakers = Speaker.with_videos.order(:name).map do |s|
    { name: s.name, bio: s.bio, alternative_names: s.alternative_names || [] }
  end

  File.open("db/seeds/speakers.marshal.gz", "wb") do |f|
    gz = Zlib::GzipWriter.new(f)
    gz.write(Marshal.dump(speakers))
    gz.close
  end

  # Same pattern for video metadata...
end
```

Marshal + Gzip keeps the files compact. 281 speakers compress to about 3 KB. The video metadata (2,675 entries with speaker and topic associations) fits in roughly 35 MB. Both get committed to the repo and loaded during `db:seed` on deploy. No runtime LLM calls needed on the production server.

## What I'd change

The implicit rate limiting through Solid Queue concurrency has worked so far, but it's fragile. If I added more queue workers or switched to a provider with tighter limits, I'd start hitting 429s. A simple delay between jobs or explicit concurrency controls would be more resilient.

Speaker deduplication was entirely reactive. Run extraction, notice duplicates, merge, repeat. A dedicated resolution step after extraction (cluster similar names, review, then merge) would catch duplicates before they reach the database. The current approach works because the speaker list is fairly stable at around 280 people across a specialized content library. It wouldn't hold up with thousands of unique speakers.

Marshal is Ruby-specific and opaque. You can't inspect the seed files or diff them meaningfully in git. JSON Lines with gzip would be slightly larger but debuggable. For data where git diffs matter, that tradeoff is worth making.

I expected the LLM call to be the interesting part of this project. Groq returns structured JSON in 175ms and that part just works. Most of my time went into the surrounding code: normalizing speaker names across variations, preventing the model from inventing categories, handling videos with barely any metadata, and shipping results from dev to a production server without LLM access. I'm still merging the occasional duplicate speaker when I notice one in search results.
