Right now I have four terminal tabs open. Each one is running a Claude Code session in a different git worktree of the same repository. One is migrating our deployment from Heroku to Kamal. Another is fixing a sales attribution bug. A third is building an API events pipeline. The fourth is working through a Shopify integration. All four are advancing simultaneously, on the same codebase, without stepping on each other.

In my [last post](/blog/from-autocomplete-to-autonomy), I mentioned worktrees in passing: four sentences about parallel development buried in a broader piece about AI-directed workflows. But worktrees have become so central to how I use Claude Code that they deserve their own treatment. This is the practical guide I wish I'd had when I started: how to set it up, what the daily workflow actually looks like, the coordination overhead nobody warns you about, and when the whole approach falls apart.

## The single-threaded developer

Even with Claude Code, most developers I talk to work serially. Prompt, wait for implementation, review the output, iterate, merge, move on to the next thing. It's faster than writing code by hand, sure. But you're still single-threaded. You're still blocked while Claude works, or while tests run, or while you're reviewing a diff.

At BSPK, the work doesn't arrive in neat sequential order. One particular week, I needed to ship a Kamal migration, a sales attribution fix, an API events pipeline, and a Shopify webhook integration. All were independent. None could wait for the others. Working serially, that's a full week of context-switching between unrelated features, losing mental state every time I swap, rebuilding context with each new prompt.

Working in parallel, all four advance at the same time. I rotate between sessions, reviewing output in one while Claude implements in another. The total calendar time compresses dramatically, not because each individual task goes faster, but because the idle time between tasks disappears.

The constraint was never Claude Code's speed. It was me, sitting there watching one session, waiting for it to finish before starting the next thing.

## Git worktrees in 60 seconds

If you've never used worktrees, the concept is straightforward. Normally, a git repo has one working directory tied to one branch. Worktrees let you check out multiple branches simultaneously, each in its own directory, all sharing the same underlying `.git` store.

```bash
# Create a worktree for a new feature branch
git worktree add ../myapp-kamal-migration -b kamal-migration

# Create another for a different feature
git worktree add ../myapp-sales-fix -b fix-sales-attribution

# See all active worktrees
git worktree list

# Clean up when a branch is merged
git worktree remove ../myapp-kamal-migration
```

Your directory structure ends up looking like this:

```
~/code/
├── bspk-web/                    # main worktree (main branch)
├── bspk-web-kamal-migration/    # worktree (kamal-migration branch)
├── bspk-web-sales-fix/          # worktree (fix-sales-attribution branch)
├── bspk-web-events-pipeline/    # worktree (api-events-pipeline branch)
└── bspk-web-shopify/            # worktree (shopify-integration branch)
```

Each directory is a fully functional checkout. You can run tests, start a server, install dependencies, all independently. But they share the git object store, so creating a worktree is nearly instant (no cloning, no network) and branches are visible across all of them.

One restriction: you can't have the same branch checked out in two worktrees simultaneously. Git enforces this to prevent conflicting writes to the same branch. In practice, this is never an issue because each feature gets its own branch anyway.

## One worktree, one Claude Code session

The core mechanic is simple: `cd` into a worktree and run `claude`.

```bash
# Terminal tab 1
cd ~/code/bspk-web-kamal-migration
claude

# Terminal tab 2
cd ~/code/bspk-web-sales-fix
claude

# Terminal tab 3
cd ~/code/bspk-web-events-pipeline
claude

# Terminal tab 4
cd ~/code/bspk-web-shopify
claude
```

Each Claude Code session operates in complete isolation. It reads its own copy of the files. It sees its own `CLAUDE.md`. It makes commits on its own branch. When it runs `git status`, it only sees changes in its worktree. When it runs tests, it runs them against its own working directory.

The mental model that works best: think of each session as a separate developer sitting at a separate laptop, working on a separate branch. They happen to share the same git history, but their day-to-day work is completely independent. They don't see each other's uncommitted changes. They don't interfere with each other's test runs.

This isolation is what makes the whole thing work. Claude Code doesn't need to know about the other sessions. It doesn't need coordination protocols or locking mechanisms. Each session just works on its own branch in its own directory, exactly like it would if it were the only session running.

## What my actual workflow looks like

The morning starts with figuring out what's in flight. I'll check my branches, see what's ready for review, what's mid-implementation, what hasn't started yet. Then I create or resume worktrees as needed.

I usually start the day by kicking off the session that needs the least oversight. Something like a well-defined refactoring or a bug with a clear reproduction. I'll write the prompt, put Claude in plan mode, review the plan, approve it, and move on while it implements.

Then I switch to the next terminal tab and do the same thing. Write a prompt, review a plan, approve. By the time I've set up the second or third session, the first one usually has output ready for me to look at.

The rest of the day is rotation. Check session 1, review a diff, leave a comment or approve. Switch to session 2, it's waiting for input on an approach decision, I answer and let it continue. Session 3 has failing tests, I read the output and give direction. Session 4 just finished, I review the full changeset.

My role shifts from developer to something closer to a project manager who also happens to do code review. I'm not writing code in any of the sessions. I'm prioritizing which session needs my attention, making architectural decisions, catching mistakes in review, and keeping all four streams moving forward.

I won't pretend this is relaxing. You're context-switching between four different features, each with its own state. I keep notes on what each session is doing and what I'm waiting for. And there's a practical ceiling. I've found that four simultaneous sessions is about my limit. Beyond that, my review quality drops noticeably. I start rubber-stamping changes instead of actually reading them, which defeats the purpose.

Three sessions is probably the sweet spot for most people. Four if the tasks are well-isolated and you're disciplined about taking review seriously.

## Keeping things from colliding

Parallel development sounds great until two branches touch the same file. This section is about the coordination overhead, because it's real, and pretending it doesn't exist would be dishonest.

### Merge conflicts

The simplest mitigation: pick tasks that don't overlap. If you're migrating deployment infrastructure, that mostly touches config files and CI pipelines. A sales attribution bug lives in model logic and tests. An API events pipeline is new code in a new directory. A Shopify integration touches webhooks and background jobs. These are naturally isolated.

When overlap does happen (and it will), the fix is just standard git. Merge one branch first, then rebase the other onto the updated main. The rebase might have conflicts, but they're usually small because you chose independent tasks in the first place.

```bash
# After merging kamal-migration into main
cd ~/code/bspk-web-sales-fix
git fetch origin
git rebase origin/main

# Resolve any conflicts, then continue
git rebase --continue
```

### Database migrations

This one catches people off guard. Two worktrees that both add migrations can collide in surprising ways: duplicate timestamps, conflicting schema changes, migration ordering issues.

The cleanest solution for Rails: each worktree gets its own development database. Set a different `DATABASE_URL` or use SQLite with a worktree-specific path. That way each worktree can run its own migrations without interfering with the others.

When it's time to merge, you might need to renumber timestamps or reconcile schema changes. This is annoying but infrequent if you're choosing independent tasks.

### Tests

Each worktree runs its own test suite against its own code. Tests passing in worktree A and tests passing in worktree B doesn't guarantee they'll pass after merging A and B. This is the same problem any team faces with parallel branches, it's just more visible when you're the entire team.

My approach: after merging one branch, I run the full suite on main before merging the next. It takes a few minutes but catches integration issues early.

### Rebasing

With four branches in flight, you're rebasing more often than in a typical single-branch workflow. Every time you merge one branch into main, the other three might need a rebase. Most of the time this is clean because the branches touch different parts of the codebase. Occasionally it's not, and you spend ten minutes resolving conflicts. That's the cost of parallelism, and it's usually worth it.

## When this doesn't work

I want to be direct about the situations where parallel worktrees are more hassle than they're worth.

**Tightly coupled changes.** If two features need to share new code (a new shared module, a shared migration, a common API), building them in separate worktrees creates duplication or merge headaches. Better to build them sequentially, or build the shared foundation first, merge it, then parallelize the features that depend on it.

**Unfamiliar territory.** The whole approach depends on reviewing AI output quickly and accurately. If you're working in a part of the codebase you don't know well, or using a technology you're learning, your review quality drops. Running four sessions in unfamiliar code means four sessions of low-quality review. Better to go deep on one thing and actually learn it.

**Small tasks.** Setting up a worktree, starting a session, writing a prompt, reviewing a plan. There's overhead. If the task is a quick config change or a one-line fix, just do it on main. The parallel workflow pays off for tasks that take at least 15-20 minutes of Claude time.

**Heavy migration overlap.** If your week's work involves three features that all need database migrations touching related tables, the merge overhead will eat most of your time savings. Sequence those and parallelize something else.

## The identity shift

I merged all four of those branches that week. Kamal migration, sales fix, events pipeline, Shopify integration, all reviewed, tested, and shipped. I don't think I could have done that in a week working serially, even with Claude Code. The calendar time compression is real.

But the thing that sticks with me isn't the productivity. It's how different the work feels. I spend most of my day reading code, not writing it. I'm making judgment calls about architecture and approach, not typing out implementations. I'm managing parallel workstreams the way a tech lead manages a team, except the team is AI sessions and I'm doing all the code review myself.

That shift isn't always comfortable. There are days when I want to just write code, get in the flow, solve a problem with my hands on the keyboard. And I still do that sometimes. Not everything needs to be a Claude Code task, and not everything needs to be parallelized.

But when there's a week with four independent features that all need to ship? Worktrees and Claude Code turn that from a stressful sprint into a manageable rotation. The constraint on how much I can ship moved from "how fast can I write code" to "how many contexts can I hold at review quality." That's a different kind of bottleneck, and honestly, a more interesting one to push against.
