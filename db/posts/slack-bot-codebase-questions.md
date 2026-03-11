Last month, someone on the product team posted in Slack: "How does proxy phone SMS work?" It's the kind of question that would normally land on me. I'd stop what I'm doing, grep through the codebase, trace the logic, and write up a summary. Twenty minutes, maybe thirty if the feature touches multiple services. Now a bot handles it. An Elixir app connects to Slack, runs Claude Code CLI against our codebase, and posts the answer in the thread. The whole thing took about a week to build.

## The problem

BSPK is a clienteling platform for luxury retail. The codebase has over 270 API endpoints, multi-tenancy across brands like Dior and Cartier, Shopify integrations, an AI assistant with tool use, behavioral analytics, and all the other things that accumulate in a product that's been in active development for years.

Questions about the codebase come from everywhere. Engineers on the team ask how specific subsystems work before touching unfamiliar code. QA asks what the expected behavior should be for an edge case they found. Product managers ask how a feature works so they can scope changes. Sometimes it's a new hire trying to understand why something was built a certain way.

These questions all end up with whoever has the most context on that part of the code. At BSPK, that's usually me. It's not that I mind answering, it's that every answer costs a context switch. I'm mid-implementation on something, a Slack message pops up, I stop, go read the relevant code, write a thoughtful answer, and then spend five minutes remembering where I was.

Documentation doesn't solve this. We have docs, but they go stale the moment someone refactors a module or adds a new flag. The code is the source of truth. The problem is that not everyone on the team can read it, and even the people who can don't always know where to look.

The real questions people ask aren't vague. They're specific: "How does multi-tenancy work for API authentication?", "Is there a waitlist model or is that handled through the Company status?", "How does Shopify sync product data to our system?" These all have precise answers buried in the code. You just need something that can find them.

## Why Claude Code CLI

I didn't want to build a RAG pipeline. I've built those before, and the tuning is endless: chunk size, overlap, embedding models, retrieval scoring, re-ranking. Every parameter is a knob you have to get right, and when the codebase changes, your embeddings go stale unless you re-index.

Claude Code already knows how to explore codebases. It has built-in tools for reading files, globbing for patterns, grepping for content. When you ask it a question about code, it decides which files to look at, reads them, and synthesizes an answer. That's exactly what I was doing manually when someone asked me a question on Slack.

The `--print` flag runs Claude Code in non-interactive mode. Give it a prompt, it works through the question, and it outputs the result. Pair that with `--output-format stream-json` and you get structured events as it works: which tools it's calling, what files it's reading, when the result is ready.

Here's the core invocation:

```bash
claude -p "How does proxy phone SMS work?" \
  --output-format stream-json \
  --model sonnet \
  --allowedTools "Read,Glob,Grep,Write,Edit" \
  --add-dir ./channels/C07BX1234
```

That's the entire "AI engine." No embeddings database, no retrieval pipeline, no custom search index. The CLI does the exploration, reads what it needs, and answers. Everything else in the Elixir app is plumbing to connect this to Slack.

## Architecture

The app is built in Elixir with OTP. Not because Elixir is trendy, but because the concurrency model fits perfectly. Each question from Slack gets its own GenServer process. If one question causes an error or times out, it dies in isolation. The supervisor restarts nothing because each question is a one-shot process that's expected to terminate after answering.

I went with Slack's Socket Mode instead of webhooks. Socket Mode opens a WebSocket connection from the app to Slack, so there's no public endpoint to expose. The app runs on the same server as the BSPK codebase (it needs filesystem access to the repo), and I didn't want to deal with routing external webhook traffic to it. WebSocket connects outbound, firewall stays closed.

The Claude CLI subprocess runs through an Erlang Port. Ports are Erlang's mechanism for communicating with external processes: you spawn a command, get a bidirectional pipe to its stdin/stdout, and receive messages as data arrives. The CLI writes stream-json events to stdout, and the Port delivers them line by line to the GenServer.

The flow looks like this:

```
Slack message
  → Socket Mode event handler
    → spawns QuestionWorker (GenServer)
      → opens Port (claude CLI subprocess)
        → streams tool_use events (file reads, searches)
        → streams result event (final answer)
      → posts/updates Slack message via API
    → GenServer terminates
```

Each layer handles one concern. The event handler decides whether to respond (is it a mention? a DM? is it in a thread we're already handling?). The QuestionWorker owns the lifecycle of one question: start the CLI, stream events, update Slack, clean up. The Port is just a pipe to the subprocess.

## Channel-scoped memory

This is the feature that turned the bot from "interesting demo" into something the team actually uses daily. Each Slack channel gets its own folder in the app: `channels/<channel-id>/`. Inside that folder is a `CLAUDE.md` file.

The `--add-dir` flag tells Claude Code to treat that folder as additional context, without changing the working directory (which stays pointed at the BSPK repo). So Claude can read the full codebase and also read the channel's `CLAUDE.md` for extra guidance.

Here's what a channel-specific `CLAUDE.md` looks like in practice:

```markdown
# Shopify Integration Channel

This channel focuses on Shopify-related questions. When answering:
- Start with the webhook processing pipeline (app/services/shopify/)
- The main sync logic is in ShopifyDataSyncService
- Product variants map to our Item model, not Product
- Multi-tenancy: each Company has its own Shopify credentials

## Common questions
- "How does product sync work?" → Start with ShopifyWebhookHandler
- "What triggers a re-sync?" → Check the ScheduledSyncJob
```

Teams curate these files themselves. The Shopify channel's `CLAUDE.md` points Claude toward webhook handlers and sync services. The QA channel's file lists the most common areas people ask about. The bot gets better at answering the kinds of questions that come up in each channel because the context is tailored.

Thread history adds another layer. When someone asks a follow-up in the same thread, the bot includes the last 20 messages as context. So you can have a multi-turn conversation: "How does proxy phone SMS work?" followed by "What happens when the proxy number expires?" and Claude has the prior answer to build on.

I also scope the Write and Edit tools to the channel folder only. Claude can write notes to `channels/<channel-id>/` (for its own reference on future questions) but can't modify the main codebase. This was a deliberate guardrail. I trust the tool scoping, but I also want zero chance of a Slack question accidentally triggering a code change.

## The progress UX

Claude Code doesn't answer instantly. It reads files, searches for patterns, sometimes backtracks and reads more files. A question about multi-tenancy might involve reading the authentication middleware, the Company model, the tenant-scoping concern, and a few controller examples. That takes ten to thirty seconds.

Without feedback, the user stares at nothing and wonders if the bot is working. So I built a real-time progress display. As Claude works, the bot posts a single Slack message and updates it in place with what's happening: "Reading `app/models/company.rb`", "Searching for phone proxy logic", "Reading `app/services/twilio/proxy_phone_service.rb`".

The progress comes from the `stream-json` output. Each tool invocation emits a `tool_use` event with the tool name and input. For `Read`, the input includes the file path. For `Grep`, it includes the search pattern. I extract these and format them as progress lines.

```elixir
defp format_progress(%{"type" => "tool_use", "tool" => "Read", "input" => input}) do
  path = input["file_path"] |> String.replace(~r{^.*/bspk-web/}, "")
  "Reading `#{path}`"
end

defp format_progress(%{"type" => "tool_use", "tool" => "Grep", "input" => input}) do
  "Searching for `#{input["pattern"]}`"
end

defp format_progress(%{"type" => "tool_use", "tool" => "Glob", "input" => input}) do
  "Looking for files matching `#{input["pattern"]}`"
end
```

The Slack message updates are throttled to one every 1.5 seconds. Slack's `chat.update` API has rate limits, and if Claude is calling multiple tools quickly, you'll hit them. The GenServer accumulates progress events and flushes them on a timer. Each flush replaces the entire message content with the latest progress state, plus a spinner indicator at the bottom.

When the result arrives, the bot does a final `chat.update` that replaces the progress lines with the actual answer. The conversion from Markdown to Slack's mrkdwn format handles the common cases: fenced code blocks become Slack code blocks, inline code stays as backtick-wrapped, links convert from `[text](url)` to `<url|text>`, and tables get converted to fixed-width text since Slack doesn't render Markdown tables.

## Reliability and edge cases

Slack retries. If your app doesn't acknowledge an event quickly enough, Slack sends it again. And again. Without dedup, the bot would answer the same question multiple times.

I use an ETS table as a fast dedup cache. When an event arrives, the handler checks ETS for the event's unique ID. If it's there, the event is dropped. If it's not, the ID is inserted with a timestamp and processing continues.

```elixir
def already_processed?(event_id) do
  case :ets.lookup(:processed_events, event_id) do
    [{^event_id, _timestamp}] -> true
    [] ->
      :ets.insert(:processed_events, {event_id, System.monotonic_time()})
      false
  end
end
```

A periodic task sweeps entries older than five minutes. Events won't be retried after that window, so keeping them longer would just waste memory.

The 5-minute timeout was one of the first things I added. Some questions send Claude down a rabbit hole: it reads a file, follows an include, reads that file, finds a reference, reads another file. If the question is broad enough ("How does the entire AI assistant work?"), this can go on for a while. The GenServer sets a timeout when it starts, and if the Port hasn't delivered a result by then, it kills the subprocess and posts a message saying the question was too broad to answer within the time limit.

There's also the `CLAUDECODE` environment variable. Claude Code sets this when it's running, and if the variable is present when you try to start a new instance, the CLI detects it as a nested session and changes its behavior. Since the Elixir app runs on the same machine where I sometimes use Claude Code for development, the env var can leak into the bot's subprocess. The fix is straightforward: explicitly unset it in the Port's environment.

```elixir
Port.open({:spawn_executable, claude_path}, [
  :binary,
  :exit_status,
  {:line, 65_536},
  {:env, [{'CLAUDECODE', false}]},
  {:args, build_args(question, channel_dir)}
])
```

Setting an env var to `false` in Erlang Port options removes it from the subprocess environment. I spent more time debugging this than I'd like to admit. The symptom was the CLI starting but behaving differently than expected, and the error messages didn't point at the env var at all.

Port crashes are isolated by design. If the Claude process segfaults, exits with a non-zero code, or gets killed by the OS, the Port sends an `{:exit_status, code}` message to the GenServer. The GenServer posts "Something went wrong" to the Slack thread and terminates. Other questions being answered concurrently in other GenServer processes are unaffected.

## What people actually ask

The range is wider than I expected. Engineers ask implementation questions: "How does the authentication middleware determine the current tenant?", "What validations exist on the Client model?", "Where does the Shopify webhook signature verification happen?" These are questions they could answer themselves by reading code, but the bot saves them the search time.

Non-engineers ask differently. Product managers ask "How does the waitlist feature work?" not "What does the WaitlistService class do?" QA asks "What should happen when a client is archived and then the company is deactivated?" Claude handles both kinds well. It adapts the depth of its answer to how the question is framed. A feature-level question gets a feature-level answer. A code-level question gets code references and implementation details.

Cross-cutting questions are where the bot really saves time: "How does data flow from a Shopify order to a sales attribution in our system?" Answering that manually requires tracing through webhook handlers, background jobs, plain Ruby classes, and model callbacks. Claude follows the same trail but does it in thirty seconds instead of twenty minutes.

There are limitations. The bot reads code. It doesn't have access to runtime state, logs, or production data. "Why is this endpoint slow?" is out of scope because performance is a runtime concern, not a code structure concern. "What does this endpoint do?" is squarely in scope. I've considered adding read-only database access as a tool, but I haven't needed it yet.

## What I'd change

The CLI starts up fresh for every question. There's no persistent session, so each question pays the initialization cost. For Sonnet, that's a few seconds of overhead before any tool calls start. A persistent subprocess that accepts questions on stdin would be faster, but the CLI doesn't support that mode and honestly the startup cost is tolerable.

Cost is worth mentioning. Every Slack question runs a Sonnet session that might read a dozen files. At scale, that adds up. We're a small team, so the volume is manageable, but if fifty people were asking ten questions a day, I'd need to think about caching or a cheaper model for simple questions.

There's no caching at all right now. If three people ask "How does multi-tenancy work?" on the same day, Claude reads the same files three times and generates three answers. Caching would help with cost but introduces staleness. The codebase changes daily. A cached answer from Monday might be wrong by Wednesday. For now, fresh answers every time is the right tradeoff.

I'd also like to add more tools: read-only database queries for things like "How many companies use feature X?", Sentry integration for "What errors does this endpoint throw in production?", and maybe GitHub PR history for "When was this feature last changed?" Each tool would expand the kinds of questions the bot can answer without changing the core architecture.

## A few weeks in

This is still an experiment. The bot has been running for a few weeks and it handles the majority of "how does X work" questions that used to land on me or another senior engineer. It's not perfect: sometimes it reads the wrong files and gives an incomplete answer, sometimes the 5-minute timeout isn't enough for a genuinely complex question. But most of the time, it gives a useful answer within thirty seconds.

I might end up going a completely different direction. Running the full CLI per question is convenient but expensive and slow to start. A lighter approach using the Claude API directly with custom tool implementations might make more sense long-term. Or maybe a hybrid where simple questions hit a cheaper model and complex ones get the full CLI treatment. I'm not committed to this architecture; I'm committed to the outcome of the team being able to self-serve codebase questions.

Most of the intelligence in this version is Claude Code's. The Elixir app is plumbing: receive a Slack event, run a CLI command, stream the output back. The interesting engineering is in the channel-scoped memory and the progress UX, but even those are thin layers around what the CLI already provides.

The part I didn't expect is how channel memory compounds. Teams add context to their `CLAUDE.md` files when they notice the bot getting something wrong or missing context. The Shopify channel's file has grown from three lines to a page of guidance. Each addition makes future answers in that channel more accurate, regardless of which approach powers the bot underneath. That accumulated context is the real asset, not the specific implementation.
