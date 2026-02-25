# hencf.org

Personal website and blog for [Henrique Cardoso de Faria](https://hencf.org), built with Rails 8.1 and SQLite3.

## What's here

- **Homepage** — about, experience, community involvement, and consulting services
- **Blog** — posts written in Markdown, rendered with Redcarpet + Rouge
- **AI Chat** — an LLM-powered conversational agent (RubyLLM + Groq) that can search blog posts and site content
- **/uses** — tools and setup

## Stack

- **Ruby on Rails 8.1** with Ruby 4.0
- **SQLite3** for everything — primary data, cache (Solid Cache), jobs (Solid Queue), WebSockets (Solid Cable)
- **Hotwire** (Turbo + Stimulus) for interactivity
- **Propshaft + Import Maps** — no Node.js, no build step
- **Kamal + Docker** for deployment, with Thruster as the HTTP proxy
- **Ahoy** for cookie-free, server-side analytics

## Development

```bash
bin/setup       # Install deps, prepare DB, start dev server
bin/dev         # Start development server (port 3000)
bin/ci          # Full CI suite: lint, security, tests
```

## Tests

```bash
bin/rails test              # Unit + integration tests
bin/rails test:system       # System tests (Capybara)
```

## License

The code is open source. Blog post content (`db/posts/`) is copyrighted.
