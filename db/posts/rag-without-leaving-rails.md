I wanted to build a chat that could answer questions about a religious knowledge base: 34 books of Christian spiritualist theology and over 6,000 YouTube lecture transcripts. The kind of thing where you ask "what does this tradition teach about the afterlife?" and it pulls the relevant passages from the source texts, cites the chapter and page number, and synthesizes an answer.

Every RAG tutorial I found started the same way: Python, LangChain, Pinecone or Weaviate, OpenAI embeddings. A whole separate stack from the Rails app that would actually serve the chat. I didn't want to run two runtimes, maintain two deployment pipelines, or learn a framework just to glue an LLM to a database query.

So I built the entire pipeline in Rails. The app is called [Guia](https://guia.tv), and the RAG architecture uses four components: `pdf-reader` for text extraction, Ollama for local embeddings, pgvector for similarity search, and RubyLLM with Groq for chat completions. No Python. No LangChain. No hosted vector database. Deployed on a single server with Kamal.

## The data model

The knowledge base has two types of content: books and videos. Both get chunked into embeddable pieces and stored with their vector representations.

```ruby
# Books → BookChunks (with embedding)
# Videos → VideoChunks (with embedding)
```

Each chunk stores the text content, positional metadata (page numbers for books, timestamps for videos), and a 1024-dimension vector embedding. The schema looks like this:

```ruby
create_table "book_chunks" do |t|
  t.references :book
  t.text :content
  t.string :chapter
  t.string :section
  t.integer :page_start
  t.integer :page_end
  t.integer :position
  t.integer :tokens_count
  t.vector :embedding, limit: 1024
end

create_table "video_chunks" do |t|
  t.references :video
  t.text :content
  t.integer :time_start  # milliseconds
  t.integer :time_end
  t.integer :position
  t.integer :tokens_count
  t.vector :embedding, limit: 1024
end
```

The `vector` column type comes from pgvector, PostgreSQL's vector similarity extension. You enable it with `enable_extension "vector"` in a migration, and you're done. No separate database, no external service. Your vectors live right next to your data.

## Chunking: the part that actually matters

I spent more time on chunking than on any other part of the pipeline. Chunk too large and you dilute the embedding with irrelevant context. Chunk too small and you lose coherence. The sweet spot for this content was around 500 tokens with 50 tokens of overlap between consecutive chunks.

```ruby
module ChunkingSupport
  CHUNK_SIZE = 500
  CHUNK_OVERLAP = 50
  CHARS_PER_TOKEN = 4  # rough approximation

  def estimated_tokens(text)
    (text.length.to_f / CHARS_PER_TOKEN).ceil
  end
end
```

The token estimation is deliberately rough. Counting actual tokens would require running the tokenizer for the embedding model, and the precision doesn't matter here. You're aiming for a ballpark, not an exact count. If your chunks land between 400 and 600 tokens, you're fine.

For books, the chunking gets interesting because not all books have the same structure. Some are Q&A dialog format: numbered questions with authored responses. Others use traditional chapters with numbered paragraphs. Others are straight narrative prose. A single chunking strategy doesn't work for all of them.

I built a `ChapterDetector` that samples the first 15 pages and picks a strategy:

```ruby
module ChapterDetector
  def self.for(pages)
    sample = pages.first(15).map { |p| p[:text] }.join("\n")
    has_capitulo = sample.match?(/CAP[ÍI]TULO\s+[IVXLCDM]+/i)
    has_questions = sample.scan(/^\d+\.\s/).size >= 5

    if has_capitulo && has_questions
      QAndA.new(section_prefix: "Q.")
    elsif has_capitulo
      ChapterBased.new(section_prefix: "§")
    else
      Narrative.new
    end
  end
end
```

The Q&A detector matches chapter headings and numbered questions. The Narrative detector looks for numbered titles, Roman numeral headings, and all-caps section headers. Each strategy returns chapter and section labels that get stored on the chunk, so when the chat references a passage, it can say "Chapter III, Q. 132" instead of just "page 47."

This detection runs automatically during processing. Adding a new book doesn't require manual configuration. Drop the PDF in, and the processor figures out which strategy to use.

For videos, chunking is simpler. The raw transcript is an array of timed segments from YouTube's caption track. The processor concatenates segments until it hits the token target, records the start and end timestamps, and moves on. Each video chunk knows exactly which moment in the video it came from.

## Embeddings with Ollama

The embedding model is [bge-m3](https://huggingface.co/BAAI/bge-m3), a multilingual model that produces 1024-dimension vectors. It runs locally via Ollama. No API calls, no per-token billing, no rate limits.

The client is about as simple as it gets:

```ruby
class EmbeddingClient
  OLLAMA_URL = ENV.fetch("OLLAMA_URL", "http://localhost:11434")
  MODEL = "bge-m3"

  def generate(text)
    generate_batch([ text ]).first
  end

  def generate_batch(texts)
    uri = URI("#{OLLAMA_URL}/api/embed")
    response = Net::HTTP.post(
      uri,
      { model: MODEL, input: texts, keep_alive: -1 }.to_json,
      "Content-Type" => "application/json"
    )
    JSON.parse(response.body).fetch("embeddings")
  end
end
```

Two things worth noting. The `keep_alive: -1` tells Ollama to keep the model loaded in memory permanently. Without this, Ollama unloads the model after 5 minutes of inactivity, and the next request pays a cold-start penalty of several seconds while the model loads back into RAM.

And the batch endpoint (`input` as an array) is critical for processing books. Embedding chunks one at a time would take forever. Batching 50 chunks per request makes the whole pipeline practical.

Why bge-m3 specifically? It's multilingual (all my content is in Portuguese), it's small enough to run on a CPU without a GPU (the model is about 567MB), and it scores well on retrieval benchmarks. I tried `nomic-embed-text` first, but bge-m3 handled Portuguese diacritics and terminology noticeably better.

## Vector search with pgvector

For the ActiveRecord integration, I use the [neighbor](https://github.com/ankane/neighbor) gem. It adds a `has_neighbors` declaration to your models and gives you nearest-neighbor queries:

```ruby
class BookChunk < ApplicationRecord
  belongs_to :book
  has_neighbors :embedding
end

class VideoChunk < ApplicationRecord
  belongs_to :video
  has_neighbors :embedding
end
```

The retrieval layer is a `KnowledgeRetriever` that searches both chunk types and merges results:

```ruby
class KnowledgeRetriever
  DEFAULT_LIMIT = 5

  def search(query, limit: DEFAULT_LIMIT, sources: :all)
    query_embedding = @embedding_client.generate(query)

    case sources
    when :books  then search_book_chunks(query_embedding, limit)
    when :videos then search_video_chunks(query_embedding, limit)
    else              search_all(query_embedding, limit)
    end
  end

  private

  def search_book_chunks(embedding, limit)
    BookChunk
      .joins(:book).where(books: { status: :ready })
      .nearest_neighbors(:embedding, embedding, distance: "cosine")
      .first(limit)
  end

  def search_video_chunks(embedding, limit)
    VideoChunk
      .joins(:video).where(videos: { archive_status: :archived })
      .nearest_neighbors(:embedding, embedding, distance: "cosine")
      .first(limit * 3)
      .uniq(&:video_id)
      .first(limit)
  end

  def search_all(embedding, limit)
    books = search_book_chunks(embedding, limit)
    videos = search_video_chunks(embedding, limit)
    (books + videos).sort_by(&:neighbor_distance).first(limit)
  end
end
```

The video search has a deduplication step: it fetches 3x the requested limit, then picks the best chunk per video. Without this, a single long lecture would dominate every result set because all its chunks are semantically similar.

The `nearest_neighbors` method generates SQL using pgvector's cosine distance operator (`<=>`). The query plan uses an index scan if you've added one:

```ruby
add_index :book_chunks, :embedding,
  using: :hnsw,
  opclass: :vector_cosine_ops
```

HNSW (Hierarchical Navigable Small World) is an approximate nearest-neighbor index. It trades a tiny amount of recall accuracy for dramatically faster queries. For a few tens of thousands of chunks, the speedup is significant.

## The chat agent

With retrieval working, the RAG flow is straightforward:

1. User sends a message
2. Retrieve the top 5 chunks matching the query
3. Format them as context with source attribution
4. Send context + question + conversation history to the LLM
5. Save the response with structured references

```ruby
class ChatAgent
  def respond(conversation)
    last_message = conversation.messages.where(role: :user).last
    chunks = @retriever.search(last_message.content)
    context = format_context(chunks)

    chat = RubyLLM.chat(model: "openai/gpt-oss-120b")
    chat.assume_model_exists = true

    # Replay conversation history
    conversation.messages.order(:created_at).last(10).each do |msg|
      chat.add_message(role: msg.role.to_sym, content: msg.content)
    end

    response = chat.ask(context + "\n\n" + last_message.content)

    conversation.messages.create!(
      role: :assistant,
      content: response.content,
      references: build_references(chunks)
    )
  end
end
```

The `add_message` call for history replay is important. An earlier version used `chat.ask()` for each historical message, which made actual API calls for every turn. `add_message` just populates the conversation context without hitting the API.

The LLM is Groq running `gpt-oss-120b`, accessed through RubyLLM's OpenAI-compatible provider. `assume_model_exists = true` skips model validation, since Groq models aren't in RubyLLM's model registry.

The `references` field stores structured JSON: book ID, chapter, page range, or video slug and timestamp. The frontend renders these as clickable links that jump to the exact page or moment in the video.

## Deploying Ollama with Kamal

The production setup runs three containers on a single server, all managed by Kamal:

```yaml
# config/deploy.yml
servers:
  web:
    hosts:
      - <%= Rails.application.credentials.server_ip %>
    env:
      secret:
        - OLLAMA_URL

accessories:
  db:
    image: ankane/pgvector:latest
    port: "127.0.0.1:5433:5432"
    env:
      secret:
        - POSTGRES_PASSWORD
    directories:
      - guia_data:/var/lib/postgresql/data

  ollama:
    image: ollama/ollama:latest
    port: "127.0.0.1:11434:11434"
    directories:
      - guia_ollama:/root/.ollama
```

The web container reaches Ollama at `http://guia-ollama:11434` via Docker's internal network. The `OLLAMA_URL` environment variable makes this configurable per environment.

After the first deploy, you need to pull the embedding model into Ollama's persistent volume:

```bash
kamal accessory exec ollama --reuse "ollama pull bge-m3"
```

The `--reuse` flag runs the command inside the existing container instead of spinning up a new one. This matters because the Ollama container's entrypoint is the `ollama` binary, so `kamal accessory exec` without `--reuse` would try to run `ollama` as the shell.

The model stays in the Docker volume across deploys. You pull it once, and the `keep_alive: -1` setting keeps it loaded in memory.

## What I'd do differently

The `estimated_tokens` approximation (dividing character count by 4) works well enough for Portuguese prose, but it underestimates for content with lots of short words or punctuation. If I were starting over, I'd use a proper tokenizer for the embedding model. The `tiktoken_ruby` gem handles this for OpenAI-compatible tokenizers, and the accuracy improvement matters when your chunks are borderline on the size limit.

I'd also add hybrid search from the start. Pure vector search sometimes misses exact keyword matches. A user searching for a specific book title or author name gets better results from traditional text search. The app now has both: semantic search via pgvector and ILIKE text search on titles and descriptions, with the results merged. Building this after the fact wasn't hard, but the retriever would have been cleaner if I'd planned for it from the beginning.

The pgvector extension worked out of the box. The `ankane/pgvector` Docker image ships PostgreSQL with the extension pre-installed, and the `neighbor` gem makes it feel like any other ActiveRecord query. If you're already running PostgreSQL, you don't need Pinecone. If you're running SQLite, look into `sqlite-vec` for a similar approach.

I keep hearing that RAG requires a specialized stack. That you need Python for the ML pipeline, a dedicated vector database for scale, and a framework like LangChain to wire it all together. For my use case (tens of thousands of chunks, single-digit concurrent users), Rails with a few gems handled everything. The PDF extraction, the chunking, the embeddings, the vector search, the chat interface, the deployment. All in one codebase, one language, one deployment target.

If your traffic or data volume demands a dedicated vector database or async embedding pipeline, you'll know when you get there. Start with pgvector and see how far it takes you.

---

*This post is part of a series on LLM integration in Rails. Next: [What Breaks When You Run an LLM 6,000 Times](/blog/llm-extraction-at-scale), where I extract structured metadata from the 6,383 video transcripts that feed this RAG pipeline.*
