# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Rails 8.1.2 application ("Site") running Ruby 4.0.1 on SQLite3. Uses the Solid suite (Solid Cache, Solid Queue, Solid Cable) backed by SQLite for cache, background jobs, and Action Cable. Deployed via Kamal with Docker containers using Thruster as the HTTP proxy in front of Puma.

## Common Commands

### Development

```bash
bin/setup              # Initial setup (bundle, db:prepare, starts dev server)
bin/setup --reset      # Reset setup (drops DB first)
bin/setup --skip-server # Setup without starting server
bin/dev                # Start development server (Puma on port 3000)
```

### Testing

```bash
bin/rails test                        # Run unit + integration tests
bin/rails test test/models/user_test.rb  # Run a single test file
bin/rails test test/models/user_test.rb:42  # Run a single test at line
bin/rails test:system                 # Run system tests (Capybara/Selenium)
```

Tests run in parallel using all available processors. Fixtures are loaded automatically.

### Linting & Security

```bash
bin/rubocop            # RuboCop check (rubocop-rails-omakase style)
bin/rubocop -a         # Auto-correct
bin/brakeman --quiet --no-pager  # Static security analysis
bin/bundler-audit      # Gem CVE audit
bin/importmap audit    # JS importmap vulnerability audit
```

### Full CI Suite (locally)

```bash
bin/ci                 # Runs: setup, rubocop, bundler-audit, importmap audit, brakeman, tests, seed test
```

### Database

```bash
bin/rails db:prepare   # Create + migrate (idempotent)
bin/rails db:migrate   # Run pending migrations
bin/rails db:seed      # Seed data
```

## Architecture

- **Frontend:** Propshaft asset pipeline, Import Maps (no Node.js), Turbo + Stimulus (Hotwire)
- **Backend:** Standard Rails MVC with `ApplicationController` enforcing `allow_browser versions: :modern`
- **Blog:** Post model with Markdown body, rendered via Redcarpet + Rouge. Routes: `/blog` (index), `/blog/:slug` (show). Each post has optional `linkedin_body` and `x_body` fields for social media posts, viewable at `/blog/:slug/share` (unlisted). `x_body` stores two tweets separated by `---`. Posts are stored as YAML+Markdown files in `db/posts/` (`<slug>.yml` for metadata, `<slug>.md` for body). The `posts:load` rake task creates or updates posts on deploy (runs in `bin/docker-entrypoint` after `db:prepare`). To add a new post: create the `.yml` and `.md` files, commit, and deploy.
- **Database:** SQLite3 for all environments. Production uses separate SQLite files for primary data, cache, queue, and cable (all in `storage/`)
- **Jobs:** Solid Queue running inside Puma (`SOLID_QUEUE_IN_PUMA=true`)
- **Deployment:** Kamal + Docker, Thruster proxy, jemalloc allocator, non-root container user
- **SEO:** OG + Twitter Card meta tags (via `content_for` in layout), JSON-LD structured data (Person, ProfessionalService, BlogPosting)
- **AI Chat:** RubyLLM + Groq (`openai/gpt-oss-120b`) at `/chat`. Session-scoped conversations, Turbo Streams broadcasting via `broadcasts_to`, 3 agent tools (search blog posts, get blog post, search site content). System prompt loaded from `public/llms.txt`. Rate limited: 20 messages/hour per session. Cleanup job deletes chats older than 30 days. ActionCable with `async` adapter in development, Solid Cable in production. Requires `GROQ_API_KEY` env var (also in Rails credentials). Chat creation requires `assume_model_exists = true` and `provider = :openai` on the Chat instance before save.

## CI (GitHub Actions)

Five parallel jobs on PRs and pushes to `main`: `scan_ruby` (brakeman + bundler-audit), `scan_js` (importmap audit), `lint` (rubocop), `test` (unit/integration), `system-test` (capybara with screenshot upload on failure).

## Code Style

Uses `rubocop-rails-omakase` (Rails default opinionated style). Run `bin/rubocop` before committing.
