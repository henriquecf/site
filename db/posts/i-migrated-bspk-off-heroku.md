I rewrote my homepage tagline last week. It used to say *I build things with Ruby, Elixir, and a healthy obsession with AI*. Now it says: *I'm an agentic engineer. I orchestrate AI agents to ship production software*.

That's a stronger claim than I would have made even three months ago. So I should probably explain what I've been doing that makes it true.

Over the last two and a half months, mostly solo, I migrated BSPK's entire production stack off Heroku to AWS. BSPK is a unified clienteling and commerce platform used by luxury brands like Dior and Cartier. It runs on Ruby on Rails with an Elixir/Phoenix PubSub service alongside it. We had been on Heroku for years.

The cutover happened without downtime. The new infrastructure costs more than 60% less. We kept shipping product features at the same pace throughout, including a new waitlist data model, per-SA reporting, and a bunch of smaller things that don't fit a tagline but pay the bills.

I didn't write much of the code that did this.

## What actually moved

A migration of this size has a lot of pieces. The short version, for people skimming:

- Heroku to AWS EC2, deployed with Kamal 2 and provisioned with Terraform
- Postgres to PlanetScale, with the read replica being added this week
- Redis to Upstash
- Elasticsearch to Elastic Cloud (this one I had help on, the rest I drove solo)
- An Elixir Phoenix PubSub service moved off Gigalixir onto Kamal too
- Heroku CDN to CloudFront in front of the Rails assets
- Route 53 weighted DNS to do the cutover gradually
- Tailscale for private networking between hosts
- 1Password as the secrets backend, with Kamal pulling them at deploy
- pg_squeeze and pghero for the Postgres maintenance and visibility we never had on Heroku
- A 32GB VPS we already used for development became the Kamal remote builder, which made CI deploys faster than they ever were on Heroku
- CloudWatch monitoring, 30-day log retention, post-deploy smoke tests in CI
- A two-step cutover playbook documented in the terraform README so anyone could run it

Plus the not-so-glamorous things: ghostscript installed in the runtime image so Paperclip's PDF processing kept working, a fix for `ENCRYPTION_SERVICE_SALT` being double-escaped by Kamal, a TextEncryptor SHA1/SHA256 dance to keep encrypted values readable across the cutover window. Migrations always have these. They're not what I want to write about today.

Why AWS specifically? Because our CEO asked for AWS. On almost any cheap VPS provider, the cost reduction would have been bigger. AWS was a constraint, not a preference. I priced it both ways before starting.

## What "directing agents" actually meant

Most of my time was spent reading and deciding, not typing.

Before any non-trivial change, I had Claude produce a plan. Not a vague plan. A plan with the specific files it intended to touch, the commands it would run, and the things that could break. I read it. I edited it. Sometimes I threw it out and asked for a different approach. Then the agent executed.

That sounds slow. It isn't. The agent reads the codebase faster than I do, drafts the plan in less time than it takes me to make coffee, and executes it while I'm doing something else. The bottleneck shifts from typing speed to decision quality.

I ran agents in parallel a lot. Two or three worktrees, each with its own Claude session, each working on a different feature or part of the migration. I'm not sure I could have moved this fast on the migration without parallel worktrees. Heroku to AWS isn't one project. It's a few dozen small projects, most of them blocking on something else, some of them parallelizable.

Documentation stopped being optional. The `CLAUDE.md` files in our repos got opinionated. I wrote down our Solid Queue conventions, our test fixture approach, the boring shape of our controllers, the gotchas you'd otherwise have to know to avoid stepping on. The agents read those docs every session. Keeping them current was now load-bearing work, which it always was — we just used to pretend the tribal knowledge in our heads was good enough.

The test suite is the contract now. When the agent ships more code than I can read line-by-line, I have to trust the tests to catch what I miss. We migrated from RSpec to Minitest during this stretch, partly because Minitest is faster and partly because I wanted a less mocking-friendly culture. Mocked tests pass while production breaks. I want tests that fail when the thing fails.

Reading PRs is a different skill now. I review fewer lines, but I read them differently. I'm looking at the shape of the change, the intent, the failure modes, not the syntax. The syntax is fine. The agent passes RuboCop. The question is whether the agent understood what we wanted, and that's not a question RuboCop can answer.

## A small moment that made it click

The clearest moment for me was a Caddy boot loop on the new EC2 host one evening during a dry-run cutover. The proxy was crashing on startup, restarting, crashing again. I had nothing useful to go on except a nondescript error in the logs.

I described what was happening to Claude and pasted the logs. It read them, asked me one question about how the TLS was configured, then proposed hardcoding `tls_enabled true` instead of letting it derive from the environment. I read the diff, agreed, applied it. Boot loop gone.

The fix took five minutes. Six months ago I would have spent forty minutes on the same problem. Not because I'm bad at debugging, but because Claude was already three steps into the documentation while I was still parsing the stack trace.

The leverage isn't "the AI knows things I don't." It does, sometimes. The leverage is that the AI is faster at the boring parts of investigation, willing to try things in parallel with me thinking about what they mean, and it doesn't get tired. I'm faster at the part where I decide which proposed thing matches what we actually want.

## What surprised me

I didn't get faster at writing code. I got faster at making decisions. Most of my time on the migration was spent reading: reading proposed plans, reading proposed diffs, reading documentation the agent was citing, reading our own architecture decisions to remember why a thing was the way it was. The typing was almost incidental.

The cost of context went down. Adding a new feature used to involve the warm-up tax of reloading a piece of the codebase into my head. With agents that already have the entire repository in their working memory and re-read it every session, that tax mostly disappears. I can context-switch between two features without paying the price I used to pay.

The cost of clarity went up. When I'm vague, the agent ships vague code. When I describe what I want in three sentences instead of one, I get something I don't have to redo. The skill of writing a tight description of an intended change has become more valuable than the skill of writing the change itself. That's a strange sentence to type.

I'm still bad at handing off the keyboard sometimes. There are small surgical changes where I know exactly what I want and describing it would take longer than just doing it. I've stopped feeling guilty about typing those myself. The point isn't to never type code. The point is to type only when typing is genuinely the fastest path.

## What I'm still figuring out

Trust calibration is the unsolved problem. Some areas of the codebase I let the agent ship into with minimal review because the tests are good and the surface area is small. Other areas I read every line because the blast radius of a wrong change is too large. I don't have a clean rule for which is which yet. I have intuition, and I'm wrong about my intuition more than I'd like.

Making a team agentic is harder than making myself agentic. I've done the personal version. The collective version, where everyone on a team is operating this way and the codebase reflects that, is something I'm just starting to explore. Architecture docs help. Conventions help. There's still a layer of "how does the team know what good agent work looks like" that I don't think anyone has figured out yet.

The label might not last. *Agentic engineer* is a useful phrase right now because it points at something specific that *senior software engineer* doesn't quite cover. In a year or two, maybe everyone is doing this and the label dissolves back into *engineer*. That would be fine. I'm not attached to the label. I'm attached to the work.

## What's next

I want to write a separate post that's just the migration: the Kamal configs, the Terraform modules, the gotchas, the cutover playbook in detail. That post is for ops people sitting on a Heroku bill they're tired of paying. This one wasn't really for them.

This one was for the people watching the agentic engineering conversation and wondering if anyone is actually shipping production work with it. I am. I've also got plenty I haven't figured out yet — the team angle, the trust calibration, the question of what happens to this label in a year. I'll keep writing as I figure those out.
