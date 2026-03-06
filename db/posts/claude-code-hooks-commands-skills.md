Claude edits a controller. A hook fires, scans the new code for association access patterns inside loops, and injects a warning back into the conversation: "Potential N+1 on `client.purchases` in the index action. Consider adding `.includes(:purchases)` to the query." Claude reads the warning and fixes the query before moving on to the next file. I didn't say anything. I didn't have to.

That hook is one piece of a system I've built on top of Claude Code's extensibility features: hooks, commands, and skills. Most of the Claude Code content I see focuses on CLAUDE.md and prompt engineering. Those matter, but they're static context that Claude reads once at the start of a session. The extensibility layer is where things get dynamic: automation that fires on events, prompts packaged as reusable workflows, and structured processes that connect Claude to external tools like your issue tracker or deployment pipeline.

## Hooks: event-driven automation

Hooks are shell commands that Claude Code runs in response to lifecycle events. You configure them in `~/.claude/settings.json` for global hooks or `.claude/settings.json` for project-specific ones. They fire at specific moments: before a tool runs (`PreToolUse`), after a tool runs (`PostToolUse`), when a notification is sent, or when you submit a prompt.

The configuration lives in your settings file:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/n-plus-one-check.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

This says: after every Edit tool invocation, run `n-plus-one-check.sh` with a 10-second timeout. The `matcher` field filters which tool triggers the hook. You can match on tool name (`Bash`, `Edit`, `Write`) to narrow the scope. Without a matcher, the hook fires on every tool use of that event type.

The hook receives the tool's input and output as JSON on stdin. It can return JSON with an `additionalContext` field to inject information back into the conversation. That's the feedback mechanism: the hook observes what Claude did, and if it has something to say, it talks back.

### Catching N+1 queries at edit time

The reason I built this hook: I kept finding N+1 queries in code review. Claude would write a controller action that loaded a collection, then the view would call an association on each record, and nobody caught it until I ran the test suite with query logging or noticed it in production. It happened across multiple projects, multiple sessions. The pattern was always the same: `.each` in a view or controller, with a nested association access that should have been preloaded.

Here's the hook:

```bash
#!/bin/bash
set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Only check controllers and views
[[ "$FILE_PATH" != *_controller.rb ]] && \
[[ "$FILE_PATH" != *.html.erb ]] && exit 0

NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
[ -z "$NEW_CONTENT" ] && exit 0

# Look for .each/.map with nested association access
WARNINGS=""
while IFS= read -r line; do
  if echo "$line" | grep -qE '\.(each|map|select|reject)\b'; then
    BLOCK_CONTEXT="$line"
  elif [ -n "${BLOCK_CONTEXT:-}" ]; then
    # Check for association access patterns inside the block
    if echo "$line" | grep -qE '\.[a-z_]+s(\.|$| )' && \
       echo "$line" | grep -qE '\.(name|count|size|title|email|first|last)'; then
      WARNINGS="${WARNINGS}Possible N+1: ${BLOCK_CONTEXT} -> ${line}\n"
    fi
    # Reset after a few lines past the loop
    BLOCK_CONTEXT=""
  fi
done <<< "$NEW_CONTENT"

[ -z "$WARNINGS" ] && exit 0

jq -n --arg ctx "N+1 query warning in $FILE_PATH:
$(echo -e "$WARNINGS")
Consider adding .includes() or preloading these associations." \
  '{additionalContext: $ctx}'
```

The script reads the JSON from stdin, extracts the file path and the new content Claude just wrote, and scans for the telltale pattern: an iterator (`.each`, `.map`) followed by lines that access what looks like an association. It's a heuristic, not a static analyzer. It catches the common cases and misses some edge cases. That's fine. A hook that catches 80% of N+1s at edit time is more valuable than a perfect detector that only runs in CI.

When the hook finds something suspicious, it injects a warning via `additionalContext`. Claude sees it as part of the conversation and adds the `.includes()` call. The fix happens inline, during implementation, before I even review the code.

### Other hook patterns

N+1 detection is the one I use most, but hooks cover a lot of ground:

- **PreToolUse on Bash** can validate commands before they run. You could block `git push --force` to main, or reject `rm -rf` on certain directories. The hook returns `{ "decision": "block", "reason": "..." }` to stop the tool from executing.
- **PostToolUse on Bash** can parse test failures. Claude already sees the raw output, but a hook that extracts just the failing test names and error messages as structured context helps it focus on the right failures instead of scrolling through passing tests.
- **Config dependency tracking**: I had a session where I changed Kamal's `deploy.yml` from host networking to bridge networking. Everything deployed, but the Caddyfile was still pointing `reverse_proxy` at `127.0.0.1:8080` instead of `kamal-proxy:80`. A hook that flags dependent config files when you edit infrastructure configs would have caught that before I spent time debugging why requests weren't reaching the app.

The key constraint is the timeout. Keep hooks fast. Mine reads the edited content and does a string scan, which takes milliseconds. If your hook does something heavier (running a full linter, calling an external API), increase the timeout, but know that slow hooks make every tool invocation feel sluggish.

## Commands: prompts you use more than once

If hooks are reactive, commands are intentional. A command is a markdown file in `.claude/commands/` that becomes available as a slash command. You type `/simplify` and Claude executes whatever instructions are in that file.

This command came out of a real code review session. I had a large PR on a Rails app and I wanted to check it for performance issues before merging. I found myself typing the same multi-part prompt: look for N+1 queries, check for unnecessary database calls, find hot-path bloat. The third time I typed it, I extracted it into a command:

```markdown
Review the current branch for efficiency issues.
Compare against main to scope the review to changed files.

Launch up to 3 parallel investigations:

## Agent 1: N+1 Query Detection
Review changed controllers, views, and scopes for:
- .each/.map blocks that access associations without preloading
- Collection rendering without .includes() on the query
- Counter queries that could use counter_cache
For each finding, show the file, the query pattern, and the fix.

## Agent 2: Unnecessary Database Queries
Look for:
- .count when .size on a loaded collection works
- .exists? followed by .find (two queries instead of one)
- .where queries inside loops that should be batched
- Eager loading associations that are never used in the view

## Agent 3: Hot Path Optimization
Check for:
- Expensive computation in partials rendered inside collections
- Cache-eligible content rendered without fragment caching
- Serialization of large objects when only a few fields are needed

Aggregate all findings into a single report grouped by severity.
```

When I type `/simplify`, Claude launches parallel agents that each focus on a different concern. One checks for N+1s, another looks for redundant queries, the third reviews hot paths. The findings come back as a single aggregated report. What used to be a 20-minute manual review becomes a command that runs while I'm reading the PR description.

A command is just a prompt in a markdown file. No special syntax, no API, no configuration beyond putting the file in the right directory. But packaging a prompt as a command changes how you use it. Instead of remembering three categories of performance checks and typing them out, you type one word.

The scope is determined by where the file lives. `~/.claude/commands/` makes it global, available in every project. `.claude/commands/` inside a project makes it project-specific. The `/simplify` command is global because I use it across every Rails app I work on. A command that seeds your specific project's test data would go in the project directory.

Commands accept arguments too. If the file is named `simplify.md`, you can type `/simplify --focus n-plus-one` and `$ARGUMENTS` in the markdown gets replaced with `--focus n-plus-one`. Useful for commands that operate on a specific file, PR, or concern.

When should something be a command vs. just typing the prompt? I use the "third time" rule. The first time I type a multi-step prompt, fine. The second time, I notice I'm repeating myself. The third time, I extract it into a markdown file. The threshold is low because the cost is low: creating a command takes 30 seconds.

## Skills: structured workflows

Skills are the most structured option. A skill lives in a directory under `.claude/skills/` with a `SKILL.md` file that defines the workflow, parameters, and expected output format.

### Reviewing commits against requirements

I have a skill called `/review-commit` that reviews a commit against its Linear issue:

```markdown
# Review Commit Against Requirements

Perform an architectural code review comparing a commit's
implementation against its Linear issue requirements.

## Usage

/review-commit [linear-issue-id] [commit-ref]

- linear-issue-id: e.g., BK-5302. If omitted, extracts from branch.
- commit-ref: Git commit reference (default: HEAD)

## Workflow

### 1. Gather Context
Fetch the Linear issue details and comments using MCP tools.
Get the commit diff with git show/diff.

### 2. Analyze Requirements
Extract from the Linear issue:
- Functional requirements: what the code should do
- Data/volume requirements: counts, frequencies
- Technical constraints: patterns, integrations

### 3. Compare and Identify Discrepancies

| Requirement | Expected | Implemented | Status |
|-------------|----------|-------------|--------|
| Feature X   | 5/week   | 5/day       | Wrong frequency |
| Feature Y   | Required | Missing     | Not implemented |

### 4. Generate Review Report
Structured review with corrections needed, file paths,
code snippets, and a verification plan.
```

When I type `/review-commit BK-5302`, Claude fetches the issue from Linear via MCP, reads the commit diff, and cross-references every requirement against the implementation. It catches things like "the issue says weekly but the code runs daily" or "the issue mentions a notification step but there's no mailer in the diff."

This is where MCP integrations become force multipliers. The skill doesn't just read code. It reads the requirements from Linear, the implementation from git, and produces a structured comparison. Without MCP, you'd be copying issue descriptions into the chat manually.

### Validating deployments

A second skill I use covers the deployment pipeline:

```markdown
# Deployment Validation

## Usage
/deploy-check [environment]

## Workflow
1. Validate secrets: run `kamal secrets print` and verify
   expected variables are present and non-empty
2. Build Docker image locally and check for errors
3. Push to registry
4. Run `kamal setup` or `kamal deploy`
5. Verify domain endpoint responds with 200
6. Check Caddy TLS certificate status
```

This one exists because of a specific session where three things broke in sequence during a deployment: a dotenv parsing issue mangled a secret, the Docker build failed because of a Spring boot conflict, and after fixing both, the Caddyfile was still pointing at the wrong address because I'd changed the networking mode. Each issue took its own debugging cycle. The skill encodes the verification steps so they happen in order, every time, and a missed step doesn't compound into a multi-hour debugging session.

The practical difference between a command and a skill is organizational. Skills live in their own directory, which makes it natural to include supporting files alongside the SKILL.md: output templates, example reports, reference docs on your team's conventions. Commands are single markdown files. If your workflow fits in one file, use a command. If it needs more structure, use a skill.

Skills also integrate with Claude Code's plugin and marketplace system, so you can share them or install skills others have built. I use a few from the marketplace (code-review, rails-simplifier) alongside my custom ones.

## How they compose

These features are useful individually, but the interesting part is how they chain together during a real feature workflow.

I start by typing `/review-commit BK-5302` to check whether my last implementation actually covers all the requirements from the Linear issue. The skill tells me I missed an edge case: deleted records should be excluded from the count, but my query doesn't filter them. I tell Claude to fix it.

Claude edits the controller. The N+1 hook fires, catches that the new `.where` query accesses an association inside a loop without preloading, injects the warning. Claude adds the `.includes()` call in the same turn.

Before merging, I run `/simplify` to review the full PR for efficiency. The parallel agents find a `.count` call that should be `.size` (the collection is already loaded), and a partial that could benefit from fragment caching. Claude fixes both.

If it's going to production, `/deploy-check` validates the full pipeline: secrets are correct, Docker builds, the image pushes, the endpoint responds.

Four features, each doing one thing, chaining together without explicit coordination. The hook doesn't know about the skill. The skill doesn't know about the command. They just operate on the same codebase and the same conversation, and the result is a tighter feedback loop than any single feature provides.

## Getting started

Start with a command. Pick a multi-step prompt you've typed more than twice, paste it into a markdown file in `.claude/commands/`, and use it for a few days. That's the lowest-friction entry point and it'll show you immediately whether the pattern fits your workflow.

Hooks are next. Think about what feedback you wish Claude got sooner. For me it was N+1 queries, for you it might be missing test coverage, type errors, or security patterns. The `PostToolUse` event with a matcher on `Edit` or `Bash` covers most cases. The contract is simple: read JSON from stdin, optionally write JSON with `additionalContext` to stdout. The script can be bash, Ruby, Python, whatever is fast and available.

For skills, wait until you have a workflow complex enough to need its own directory, or one that benefits from parameterized usage (like `/review-commit` taking an issue ID and commit ref). Most people won't need skills right away. Commands cover the vast majority of cases.

One thing to be aware of with `additionalContext`: it doesn't force Claude to do anything. It injects information into the conversation that Claude can act on. Write it like a note to a colleague who's mid-task, not a directive to a machine. "Potential N+1 on client.purchases, consider adding .includes(:purchases)" works better than "YOU MUST IMMEDIATELY FIX ALL QUERY ISSUES." Claude responds to clear, well-structured context the same way a good developer responds to a helpful code review comment.
