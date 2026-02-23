post = Post.find_or_create_by!(slug: "from-autocomplete-to-autonomy") do |p|
  p.title = "From Autocomplete to Autonomy: How Claude Code Changed the Way I Build Software"
  p.published_at = Time.zone.parse("2026-02-23 12:00:00")
  p.body = <<~MARKDOWN
    I haven't written a line of code in weeks. Not because I stopped working — I've actually shipped more features in the last month than in any comparable period of my career. The difference is *how* I'm shipping them.

    This is the story of how I went from AI-assisted coding to AI-directed development, and why the distinction matters more than most people realize.

    ## The autocomplete era

    Like most developers, my first taste of AI in coding was autocomplete. GitHub Copilot, then Cursor's tab completion. You write a function signature, it guesses the body. You start a test, it fills in the assertions. It was genuinely useful — maybe a 10-20% speed boost on code I already knew how to write.

    But here's the thing about autocomplete: it optimizes the wrong bottleneck. Writing code was never the slow part. *Thinking* about what to write, understanding the existing system, figuring out the right approach — that's where most of the time goes. Autocomplete made me type faster. It didn't make me think faster.

    I used Cursor for a while and tried everything it offered — tab completion, the Chat sidebar, Composer for multi-file edits, and eventually Agent mode. Each step was incrementally better. Composer was genuinely nice for refactoring across files. Agent mode started to feel different — like the tool was doing real work, not just suggesting text.

    But it still felt like I was a developer who happened to have a smart assistant. I was still the one reading files, deciding what to change, reviewing every suggestion line by line. The AI was a better autocomplete, not a collaborator.

    ## Finding Claude Code

    I started experimenting with Claude Code around November 2025. At first, honestly, it felt similar to what I'd been doing in Cursor's agent mode — just in the terminal instead of an IDE. I was still thinking in terms of "help me write this function" or "refactor this method."

    The shift happened gradually. I started giving Claude Code broader tasks. Not "write a migration to add a column" but "we need to track daily metrics for sales associates — here's how the raw events work, figure out the schema, the rollup logic, and the query layer." And it... just did it. Not perfectly on the first try, but well enough that I was reviewing and steering rather than writing.

    That was the moment I realized this wasn't a coding tool. It was a *development* tool. There's a huge difference.

    ## The shift: from writing code to directing development

    At my day job, I'm the primary backend engineer at BSPK — a clienteling platform for luxury retail brands. The Rails codebase is large, with complex domain logic, Elasticsearch integrations, Shopify webhooks, background job pipelines, and recently a whole AI layer I've been building from scratch.

    Here's what my workflow looks like now with Claude Code on the Max plan:

    **I describe the problem. Claude Code solves it.**

    That's an oversimplification, but not by much. A typical feature development session goes like this:

    1. I write a prompt describing what I need — the business context, the technical constraints, how it should integrate with existing systems
    2. Claude Code enters plan mode, reads the relevant files, and proposes an approach
    3. I review the plan, push back on things I disagree with, and approve
    4. It implements the whole thing — models, migrations, controllers, views, tests
    5. I review the output, run the test suite, and iterate if needed

    The key insight is that **I moved from writing code to writing specifications**. And honestly? Specifications are what I should have been writing all along. The hard part of software engineering was never the syntax.

    ## Real examples from the last month

    Let me get specific, because vague claims about productivity are worthless.

    ### Smart Criteria: natural language client search

    We needed a system where sales associates could search their client book using natural language. "Show me clients who bought handbags last month and haven't been contacted" should just work.

    This involved: extracting controller actions into service objects, building an LLM translation layer that converts English into Elasticsearch queries, creating Stimulus controllers for the interactive UI, adding OpenRouter as an LLM provider, and writing Playwright E2E tests to verify the whole flow.

    One feature. One Claude Code session (with iterations). A massive amount of files touched across the entire stack. The commit message alone tells the story — but what it doesn't tell you is that I didn't write any of those lines manually. I directed the architecture, reviewed every decision, caught a few edge cases Claude missed, and pushed the code.

    ### AI Assistant with swarm architecture

    We built a multi-agent AI assistant where an orchestrator routes to specialist sub-agents — Client Intelligence, Tasks & Calendar — each with their own tools for querying shopper data, purchase history, and schedules. Provider-agnostic, works with OpenAI, Groq, and local models.

    Built in a single focused session. I described the architecture I wanted (based on research I'd done on swarm patterns), Claude Code implemented it, and we iterated on the tool system and error handling.

    ### Ruby 4.0 and Rails 8.1 upgrades

    Framework upgrades used to be my least favorite task. Days of tracking down deprecation warnings, fixing gem incompatibilities, updating test suites. Claude Code handled the Ruby 3.4 → 4.0.1 upgrade — removed abandoned gems, added Ruby 4.0 bundled stdlib gems, fixed test stubs — in one session. Same with the Rails 8.0 → 8.1 upgrade.

    ### Behavioral analytics from scratch

    A pre-computed analytics layer that transforms raw API events into actionable insights. Four analytics modules (BehaviorProfiler, AutomationDetector, FunnelAnalyzer, OutcomeCorrelator), daily rollup materialization, a cron job, and a Sysop dashboard.

    I described the concept. Claude Code designed the schema, built the pipeline, and created the UI. I steered the approach and caught a timeout issue that needed Elasticsearch instead of raw SQL. That's the kind of collaboration I'm talking about — I bring the domain knowledge and architectural taste, Claude Code brings the implementation speed.

    ## What actually makes this work

    It's not just "use Claude Code and ship faster." There are specific practices that make the difference.

    ### Planning mode is everything

    The single most important feature in Claude Code is plan mode. Before any implementation, I have Claude read the relevant code, understand the existing patterns, and propose an approach. This is where I add the most value — I know the codebase, the business constraints, and the architectural direction. The plan is our contract.

    I've even set up hooks that fire when Claude enters plan mode, reminding it to check our architecture documentation first. This means every feature starts with context, not guessing.

    ### Custom hooks enforce standards

    I wrote a pre-commit hook that blocks `git add` until Claude acknowledges it has reviewed relevant architecture docs. It sounds annoying, but it's saved me from undocumented architectural decisions multiple times. The hook lists available docs and asks if any need updating. It keeps the codebase self-documenting.

    ### Worktrees for parallel development

    This is the game changer that most people miss. With Claude Code, I can run multiple features in parallel using git worktrees. Each feature gets its own isolated copy of the repo. While Claude is implementing feature A, I can review feature B, plan feature C, or context-switch to a bug fix.

    Before AI tooling, I could only work on one thing at a time because *I* was the bottleneck for every task. Now I can have three features in progress simultaneously because the implementation work is parallelized. I'm the reviewer and director, not the single-threaded executor.

    ### The CLAUDE.md file is your team's documentation

    Every project I work on has a `CLAUDE.md` at the root — it's the file Claude Code reads automatically at the start of every session. It contains the project's conventions, testing patterns, architecture decisions, and workflow rules. Think of it as onboarding documentation that actually gets used, every single time.

    ## The numbers don't lie

    I went back and looked at my git history to verify my own claims.

    In the second half of 2025, before Claude Code became my primary workflow, I made 564 commits in 6 months on the BSPK codebase. Already high output — I was pushing hard.

    Since January 26, 2026 — roughly one month — I've made 95 commits. 87 of them (92%) are co-authored with Claude. The commits are *bigger* and more detailed. Where I used to write "fix: set num of clients from ES", now a typical commit has a clear subject line, a detailed body explaining the what and why, and touches tens of files.

    I'm not just shipping more. I'm shipping better-documented, more thoroughly implemented features. The quality went up alongside the velocity.

    ## What I'm not saying

    I want to be honest about the limitations, because the hype around AI coding tools is already loud enough.

    **Claude Code doesn't replace understanding.** If I didn't deeply understand our Elasticsearch setup, I couldn't have directed the natural language search feature. If I didn't know Rails conventions, I couldn't evaluate whether the generated code was good or garbage. The AI amplifies expertise — it doesn't substitute for it.

    **Review still matters.** I review every change before it ships. Sometimes Claude makes assumptions that are technically valid but wrong for the business context. Sometimes it over-engineers a solution when a simpler approach exists. The developer's job shifted from writing to reviewing, but reviewing well requires the same depth of knowledge.

    **Not everything is a Claude Code task.** Quick one-line fixes, exploratory debugging where I need to think through a problem — sometimes I just write code the old way. The tool doesn't need to handle 100% of work to be transformative.

    **It's expensive.** The Max plan isn't cheap. For me, it pays for itself many times over because of the feature velocity it enables. But it's a real cost, and not everyone's situation justifies it.

    ## The bigger picture

    I think what's happening is a genuine shift in what it means to be a software engineer. Not the "developers will be replaced" narrative — that's lazy and wrong. More like: the job is moving up the abstraction ladder.

    We went from assembly to C to Ruby. Each step didn't eliminate programmers — it made them more productive and let them focus on higher-level problems. AI-directed development is another step on that ladder. Instead of writing the implementation, I write the specification. Instead of debugging syntax, I debug architecture. Instead of being a coder, I'm a technical director who happens to work with an AI pair.

    For senior engineers especially, this is liberating. All those years of accumulated knowledge about system design, failure modes, scalability patterns, and domain modeling — they become *more* valuable, not less. You need them to direct the AI effectively. Junior engineers writing CRUD? AI can do that. Senior engineers who know *why* the CRUD should be structured a certain way? That's irreplaceable, and now they can apply that knowledge at 10x the speed.

    I'm still early in this transition. Every week I find new ways to improve the workflow — better prompts, better hooks, better use of planning mode. But the core insight hasn't changed since that first moment when I realized Claude Code wasn't just helping me write code. It was helping me *build software*.

    And those are two very different things.
  MARKDOWN
end

post.update!(
  linkedin_body: <<~LINKEDIN.strip,
I haven't written a line of code in weeks — and I've shipped more features in the last month than in any comparable period of my career.

I went from GitHub Copilot's autocomplete to Cursor's agent mode to Claude Code, and each step changed not just my speed but how I think about the work itself.

The real shift? I stopped writing code and started writing specifications. I describe the business context, the technical constraints, how it integrates with existing systems — and Claude Code handles the implementation. I review, steer, and iterate.

Some of what I shipped this way at BSPK (a clienteling platform for luxury retail):
- Natural language client search powered by LLM-to-Elasticsearch translation
- A multi-agent AI assistant with swarm architecture
- Ruby 4.0 and Rails 8.1 framework upgrades
- A full behavioral analytics pipeline from scratch

92% of my recent commits are co-authored with Claude. The commits are bigger, better documented, and more thoroughly tested.

But I want to be clear: this doesn't replace understanding. If I didn't deeply know our Elasticsearch setup, Rails conventions, and business domain, I couldn't direct any of this effectively. AI amplifies expertise — it doesn't substitute for it.

The developer's job is moving up the abstraction ladder, just like it did from assembly to C to Ruby. Senior engineers who know *why* code should be structured a certain way? That knowledge just became 10x more leveraged.

Full post: https://hencf.org/blog/from-autocomplete-to-autonomy
  LINKEDIN
  x_body: <<~XPOST.strip
I haven't written a line of code in weeks.

Not because I stopped working — I've shipped more features in the last month than in any comparable period of my career.

I went from autocomplete → agent mode → AI-directed development. Here's what actually changed:
---
The shift: I stopped writing code and started writing specifications.

I describe the problem, the constraints, how it fits the system. Claude Code implements it. I review, steer, iterate.

92% of my recent commits are co-authored with AI. They're bigger, better documented, and more tested than before.

AI amplifies expertise — it doesn't replace it.

Full post: https://hencf.org/blog/from-autocomplete-to-autonomy
  XPOST
)
