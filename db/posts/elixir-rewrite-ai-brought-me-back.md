I have a side project that aggregates YouTube content, extracts metadata with LLMs, and serves it through search and a chat agent. It's a Rails app with PostgreSQL, Solid Queue, and Ollama for local models. Solo developer, single VPS.

A few months ago, I decided to rewrite it in Elixir.

Three things pulled me toward Phoenix. First, I wanted streaming LLM responses in the chat feature. Token-by-token output, the way ChatGPT does it. LiveView makes this feel natural. You can push tokens to the client as they arrive without setting up SSE or managing WebSocket subscriptions manually. Second, the BEAM's concurrency model. The app runs a bunch of background jobs: crawling YouTube channels, fetching transcripts, extracting metadata, generating embeddings. Elixir handles concurrent work at the runtime level. Third, I just wanted to learn Elixir. It's a personal project. That's a valid reason.

I went for a full migration, not a hybrid approach.

## The shared database trick

Before writing any Elixir, I made one decision that turned out to be the smartest part of the whole experiment: both apps would share the same PostgreSQL database.

The Phoenix app used Ecto, the Rails app used ActiveRecord, both pointing at the same tables. Ecto migrations used `create_if_not_exists` to avoid stepping on existing Rails schema. Any data created in the Elixir version was immediately available in Rails. No migration scripts, no data export.

This made the rewrite completely reversible. If Phoenix didn't work out, the data was already home.

## The rebuild

I rebuilt the app in Phoenix with Claude Code. Chat LiveView with streaming LLM responses, CMD+K spotlight search, the video platform with subdomain routing, admin screens, the RAG pipeline, Oban workers for the full crawl-to-publish pipeline.

I also used the rewrite as a sandbox for things I'd been putting off in Rails: crawled a second YouTube channel, benchmarked six local models for metadata extraction (gemma3:4b [won](/blog/extracting-metadata-local-llms)), and rewrote the chapter detection system with more strategies.

The features worked. Tests passed. I had a functional Phoenix app talking to the same database as my Rails app.

Then I went back to Rails.

## Why I came back

Not because Elixir is bad. Not because Phoenix is lacking.

The reason is more specific: writing code with AI was a noticeably worse experience in Elixir than in Ruby.

I use Claude Code for almost everything. Over 90% of my commits at work are co-authored with Claude. My setup is tuned for it: architecture docs that get loaded as context, custom hooks, plan mode for complex features, worktrees for parallel work. When I sit down to build something in Ruby, the workflow is dialed in. I describe what I want, Claude produces working code, and we iterate from there.

In Elixir, that flow broke down. The generated code had more errors. It took more rounds of back-and-forth to reach something that actually worked. Tasks that would be one-shot in Ruby required multiple iterations in Elixir, each one fixing something the previous attempt got wrong. The model knows Elixir, but there's a reliability gap compared to Ruby. That gap compounds fast when AI is writing the majority of your code.

Part of this is the model's training data. Ruby on Rails is one of the most documented web frameworks in existence. Twenty years of blog posts, Stack Overflow answers, open source projects. Elixir's ecosystem is smaller and younger. The model has less to draw from.

Part of it is my own setup. My Claude Code configuration is optimized for Ruby. The architecture docs, the project-specific instructions, the conventions files. Starting fresh in a new language means starting without all that accumulated context. Switching to a new editor and losing all your muscle memory at the same time.

The result: development was slower and rougher in Elixir. For a side project where I build in stolen hours, that friction matters.

## The language your AI knows best

This is the part I keep thinking about. When I write code by hand, language choice is about the language: its type system, its runtime characteristics, its ecosystem, how it makes me think about problems. I picked Ruby because I think in Ruby. Other people pick Go or Rust or TypeScript for similar reasons.

When AI writes most of your code, there's a new variable: how well the AI handles that language. And it's not just about the model. It's about the entire stack of context you've built around your workflow. Your project docs, your architecture notes, your conventions, your hooks, your test infrastructure. Everything that makes the AI effective in your specific codebase.

Switching languages means resetting all of that to zero.

I'm not saying everyone should use Ruby because Claude is good at Ruby. The gap will narrow as models improve and as Elixir's ecosystem grows. For a brand new project where you'd be building context from scratch in any language, the difference might not matter as much.

But for an existing project with a tuned AI workflow, the switching cost is higher than I expected. It's not just "learn a new language." It's "rebuild your entire AI development environment."

## What I brought back

The rewrite wasn't wasted time. The shared database meant everything I built in Elixir was already in PostgreSQL when I came back.

I cherry-picked three things into Rails. The expanded database: during the Elixir sandbox period, I'd crawled a second YouTube channel and processed thousands of new videos, all sitting in the shared database, ready to go. The metadata extraction approach: I benchmarked six local models during the rewrite and proved that gemma3:4b on Ollama could replace the cloud API. That work transferred directly. And the chapter detection rewrite: more strategies covering more video formats. The logic was different in Elixir (functional vs OOP), but the strategies themselves were portable.

Within a day of coming back, I had all three integrated and was shipping new features at the pace I'm used to.

## What stays with me

This isn't a "Rails is better than Phoenix" post. Elixir's concurrency model is genuinely impressive. LiveView's approach to real-time is elegant. I can see myself using Elixir for something where concurrency is the core problem, not a side concern.

But I can tackle concurrency in Ruby too. Solid Queue handles my background jobs. If I outgrow it, Ruby has async options, and they'll only get better. Rails conventions and ecosystem maturity give me a productivity baseline that's hard to match in a younger framework, especially when AI is doing most of the typing.

The streaming LLM feature that originally motivated the switch? Still on my list. It's doable in Rails with Turbo Streams or ActionCable, just with more manual wiring. The fact that it's solvable in Rails, just less elegantly, tells me the motivation was real but not strong enough to justify switching everything else.

No regrets on the experiment. I learned some Elixir, got a feel for Phoenix and LiveView, discovered things about my own project I'd been avoiding, and shipped real data work that made my Rails app better when I came back. The shared database trick made it all low-risk. If you're considering a similar experiment, point both apps at the same database. Build in the new stack, see how it feels. If it doesn't work out, you haven't lost anything.

The unexpected takeaway was about AI, not languages. When your AI development setup writes most of your code, the quality of that experience in a given language matters more than it used to. Today, Ruby has a clear edge in my workflow. That might change. But I'm not going to fight my own tools to find out.
