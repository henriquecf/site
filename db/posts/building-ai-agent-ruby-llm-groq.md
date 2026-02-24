My [last post](/blog/from-autocomplete-to-autonomy) was about how AI changed the way I build software — how I went from writing code to directing development. That post was full of claims about productivity and workflow shifts. This one is the receipt.

I built an AI chat agent for this site. It lives at [/chat](/chat). You can go try it right now. Ask it about my experience, my skills, what I've written about — it'll answer conversationally, pulling from the site's actual content. It streams responses in real-time, has tools to look up blog posts and search the site, and costs essentially nothing to run.

The whole thing was built in a single Claude Code session. Here's how.

## The goal

I wanted visitors to be able to explore my site conversationally. Not everyone wants to scroll through sections or read long blog posts. Some people just want to ask "What does this guy know about Elasticsearch?" or "Has he written anything about AI?" and get a direct answer.

The constraints were simple: it had to be cheap (ideally free), fast (no waiting seconds for a response), and simple (no infrastructure beyond what Rails already provides). No separate AI service, no Redis, no Postgres, no vector database. Just the same SQLite + Solid Queue stack the rest of the site runs on.

## The stack: RubyLLM + Groq

### RubyLLM

[RubyLLM](https://rubyllm.com) is what makes this whole thing feel native to Rails. It's not a thin API wrapper — it gives you ActiveRecord models for chats and messages, a tool framework with a clean DSL, and streaming support out of the box. Run the Rails generators and you get a `Chat` model and a `Message` model that just work.

The setup is minimal. Here's the entire initializer:

```ruby
RubyLLM.configure do |config|
  config.openai_api_key = ENV["GROQ_API_KEY"] || Rails.application.credentials.groq_api_key
  config.openai_api_base = "https://api.groq.com/openai/v1"
  config.default_model = "openai/gpt-oss-120b"

  config.use_new_acts_as = true
end
```

That's it. Five lines. RubyLLM is provider-agnostic through OpenAI-compatible APIs, so pointing it at Groq is just a base URL change. The `Chat` model uses `acts_as_chat` and the `Message` model uses `acts_as_message` — RubyLLM handles persistence, conversation history, and tool call tracking automatically.

One gotcha worth mentioning: because Groq models aren't in RubyLLM's built-in model registry, you need to set `assume_model_exists = true` and explicitly set the provider when creating a chat:

```ruby
def create_chat
  chat = Chat.new(session_id: session_id)
  chat.assume_model_exists = true
  chat.provider = :openai
  chat.save!
  chat
end
```

Without those two lines, RubyLLM tries to look up the model in its registry, fails, and raises an error. It took a few minutes of debugging to figure that out — the kind of thing that's obvious in retrospect.

### Groq

[Groq](https://groq.com) runs inference on custom hardware (LPUs) that's optimized for speed. The result: responses start arriving in milliseconds, not seconds. For a chat agent on a personal site, that speed difference is everything. Nobody wants to wait three seconds for an answer to "What does Henrique specialize in?"

The free tier is generous enough for a personal site. Even if I outgrow it, the paid pricing is a fraction of what OpenAI or Anthropic charge for comparable models. The model I'm using — `gpt-oss-120b` — isn't as capable as GPT-4o or Claude Sonnet, but it doesn't need to be. It's answering questions about my resume and blog posts, not writing legal briefs.

### What we didn't use

This is where most AI projects go wrong: they reach for complexity before proving they need it.

**No RAG pipeline.** Retrieval-Augmented Generation is great when you have thousands of documents. I have a personal site with a few sections and a handful of blog posts. The entire site's content fits comfortably in a system prompt. I literally load `public/llms.txt` into the prompt and call it a day.

**No vector database.** No Pinecone, no pgvector, no Qdrant. SQLite `LIKE` queries are fine when you're searching a few blog posts. Would this scale to thousands of documents? No. Do I have thousands of documents? Also no.

**No fine-tuning.** A well-written system prompt plus three tool classes gives the agent all the personality and knowledge it needs. Fine-tuning is for when you need the model to behave in ways that prompting can't achieve. I don't.

The lesson: start with the simplest thing that works. You can always add complexity later. You can never easily remove it.

## Tools, not just chat

The agent isn't just a chatbot with a system prompt — it's an agent with tools. The system prompt gives it base knowledge about my experience and skills (loaded from `llms.txt`), but the tools let it do deeper lookups on demand.

Here's the `SearchBlogPostsTool` — a good example of how clean RubyLLM's tool DSL is:

```ruby
class SearchBlogPostsTool < RubyLLM::Tool
  description "Search blog posts by topic. Returns titles, dates, URLs, and excerpts."
  param :query, desc: "Topic or keywords to search for"

  def execute(query:)
    posts = Post.published.where("title LIKE :q OR body LIKE :q", q: "%#{query}%")
    return { results: [], message: "No posts found matching '#{query}'" } if posts.empty?

    {
      results: posts.map { |p|
        { title: p.title, url: "/blog/#{p.slug}", date: p.published_at.to_date.to_s,
          excerpt: p.body.truncate(500) }
      }
    }
  end
end
```

You define a description (so the model knows when to use it), declare parameters, and implement `execute`. RubyLLM handles the function-calling protocol, JSON serialization, and result injection back into the conversation. Three tool classes — `SearchBlogPostsTool`, `GetBlogPostTool`, and `SearchSiteContentTool` — and the agent can look up anything on the site.

The model decides when to use tools. If someone asks "What does Henrique do?", it answers from the system prompt. If someone asks "What has he written about AI?", it calls `SearchBlogPostsTool`. This happens automatically — the model sees the tool descriptions and makes the call.

One Groq-specific quirk: some models return `reasoning_content` (chain-of-thought data) that Groq's API then chokes on if you send it back in conversation history. The fix is a simple `after_save` callback that strips those fields:

```ruby
after_save :clear_thinking_fields,
  if: -> { thinking_text.present? || thinking_signature.present? }
```

Small detail, but it would have caused cryptic 400 errors without it.

## Streaming with Turbo Streams

This is where Rails really shines. The agent streams responses in real-time — characters appear as the model generates them, just like ChatGPT. And it's all built with standard Rails primitives: ActionCable, Turbo Streams, and a background job.

Here's the core of `ChatResponseJob`:

```ruby
class ChatResponseJob < ApplicationJob
  TOOLS = [ SearchBlogPostsTool, GetBlogPostTool, SearchSiteContentTool ].freeze

  def perform(chat_id, content)
    chat = Chat.find(chat_id)

    chat
      .with_instructions(AgentContext.system_prompt)
      .with_tools(*TOOLS)
      .ask(content) do |chunk|
        if chunk.content.present?
          chat.messages.where(role: "assistant").last
            &.broadcast_append_chunk(chunk.content)
        end
      end

    chat.messages.where(role: "assistant").last
      &.broadcast_rendered_content
  end
end
```

The flow: user submits a message, the controller enqueues `ChatResponseJob`, which calls `chat.ask` with a streaming block. Each chunk gets broadcast to the browser via ActionCable. The `broadcast_append_chunk` method appends raw text to the message container. When streaming finishes, `broadcast_rendered_content` replaces the raw text with properly rendered Markdown (with syntax highlighting via Rouge).

The `Message` model uses `broadcasts_to` — standard Turbo Streams — so the connection setup is just:

```erb
<%= turbo_stream_from "chat_#{@chat.id}" %>
```

No React. No custom WebSocket code. No JavaScript framework. Hotwire handles everything. The message form submits via Turbo, the job streams chunks back, and the UI updates in real-time. It's the kind of thing that would have been a complex SPA project a few years ago.

## The cost question: Groq vs. the frontier

Let's talk money. Running an AI agent on a personal site means every conversation costs something. With Groq's free tier and `gpt-oss-120b`, that cost is effectively zero. I'm not paying per token — I'm just staying within rate limits.

The tradeoff is capability. GPT-4o and Claude Sonnet are better at nuanced reasoning, complex instructions, and edge cases. For answering "What's Henrique's experience with Rails?" — they're overkill. The 120B parameter model handles conversational Q&A about structured content just fine.

But here's the thing that matters architecturally: **switching models is a one-line change.** If I wanted to upgrade to GPT-4o, I'd change the initializer:

```ruby
config.openai_api_key = ENV["OPENAI_API_KEY"]
config.openai_api_base = "https://api.openai.com/v1"
config.default_model = "gpt-4o"
```

Everything else — the tools, the streaming, the chat persistence, the Turbo Streams broadcasting — stays exactly the same. RubyLLM's abstraction means the model is a configuration detail, not an architectural decision. The cost would go from ~$0 to maybe $0.01-0.05 per conversation, which is still nothing for a personal site.

This is the right way to build AI features: start cheap, prove the concept, upgrade if you need to.

## Built with Claude Code

This connects back to my first post. The chat agent was built in a single Claude Code session. I described what I wanted — the architecture, the constraints, the tools, the streaming behavior — and Claude Code implemented it. Models, migrations, controllers, views, jobs, tools, tests.

But I want to be clear about what "built with Claude Code" means. I made the architectural decisions: RubyLLM over other gems, Groq over OpenAI, tools over RAG, system prompt loaded from `llms.txt`. I knew what Turbo Streams could do and how ActionCable channels work. I knew the Solid Queue setup from the existing app.

Claude Code executed the implementation. I directed what to build and why. That division of labor — human architecture, AI implementation — is exactly what I described in the first post. This agent is a concrete example of it working.

## It's open source

The entire site — including the chat agent — is [open source on GitHub](https://github.com/henriquecf/site). You can read every line of code, see every tool definition, and understand exactly how it all fits together.

Go try it at [hencf.org/chat](/chat). And if you're a Rails developer thinking about adding AI features to your app: it's never been more accessible. RubyLLM, Groq's free tier, and standard Hotwire primitives. No PhD required.
