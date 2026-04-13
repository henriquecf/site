Four days after Karpathy posted his LLM Wiki gist, I started building one. Not because I needed another project, but because I had the perfect test case: 600 books already chunked and embedded, sitting in a Rails app I was building for a different purpose. I was using them for RAG. Chunked retrieval, semantic search, on-demand answers. The wiki approach proposed the opposite: read every source, compile the knowledge once, and let it compound.

Six days later, I had 679 interlinked pages, over 6,000 cross-references, and an answer to a question I'd been avoiding: the wiki is better. Not a little better. Fundamentally different.

## The Gist

Karpathy posted [the idea](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) on April 3. It got something like 15 million views and 5,000 stars in a few days, for good reason. The core argument: stop using LLMs as search engines over your documents. Instead, have them read your sources and compile a persistent, cross-referenced knowledge base. Three layers: raw sources (immutable), wiki pages (LLM-owned), and a schema file that defines the structure.

The part that clicked for me was about compounding. RAG re-derives answers from scratch every query. The wiki processes each source once, integrates it into a growing knowledge graph, and that understanding persists and builds. Karpathy's line: "The knowledge is compiled once and then kept current, not re-derived on every query."

I had 600 books on Spiritist doctrine — a 150-year tradition with deeply interconnected literature. The source material was already chunked as JSON files from a Rails app I was building. It was almost too convenient. So I pointed Claude Code at the books and told it to build a wiki.

## The First Attempt Was Garbage

Claude Code finished surprisingly fast. Too fast.

When I checked the output, only 3 of 34 initial books had actually been read. The rest were skimmed — a few chunks sampled, the rest ignored. The wiki pages were fluent, well-structured, and almost entirely generic. Claude was writing from its training data, not from the actual book content. The pages could have been written without ever opening the source files.

This was the most important lesson of the entire project. An LLM that skims produces confident, plausible summaries that look like real synthesis until you check them against the source. If you don't check, you'll never know the difference. The writing quality is identical. The grounding is completely absent.

## The Rule: Read Everything

The fix was simple and expensive. Every single chunk of every single book. No shortcuts.

I wrote it into the project's CLAUDE.md in bold: "Always read every single chunk of the book before creating wiki pages. A shallow skim produces generic pages based on training knowledge; a full read produces grounded pages with specific citations, quotes, and insights unique to each source."

For a 300-chunk book (roughly 150,000 tokens), this meant reading in batches of 30-50 chunks, taking notes on key passages, then writing the wiki pages. For Kardec's five foundational works alone, that was over 2,000 chunks, roughly 1.3 million tokens of dense 19th-century Portuguese.

It was slow. The context window filled up and reset over 15 times during the first 34 books. But the output was completely different. Instead of "Reincarnation is a key concept in spiritist doctrine," I got pages citing specific question numbers, quoting exact passages, and tracing how the same concept evolves across books written decades apart.

## What a "Read" Actually Looks Like

I built a small set of Ruby scripts around the process. `bin/process_pdf` takes a PDF or DOC file, extracts text, and chunks it at roughly 500 tokens with overlap. `bin/dump_book` outputs the chunks as human-readable text with chapter grouping and page references, and supports `--from N --to M` for batch reading.

The workflow for each book:

1. `bin/dump_book <slug> --stats` to see the structure (chapters, chunk count)
2. Read the entire book in batches of 30-50 chunks, covering everything
3. Create the book page with specific chapter references, quotes, and insights
4. Concept audit: identify every concept the book enriches, update each existing concept page with a new section and citations, create new pages if the book introduces uncovered themes
5. Update entity pages, topic pages, infrastructure files
6. Quality check: no broken wikilinks, all frontmatter valid, concept pages enriched

The CLAUDE.md schema file defines all of this in 330 lines. Page types, frontmatter formats, filename conventions, wikilink rules, language rules (English for filenames and code, Portuguese for content), and a post-ingest checklist. Without it, each session would invent its own structure. With it, book #183 follows the exact same format as book #1.

## The Compounding Effect

This is the part I didn't expect.

When Claude Code reads the first book about reincarnation (Kardec's *The Spirits' Book*), it creates a concept page with a definition and primary source citations. Clean, straightforward, one source.

When it reads the second book (*The Gospel According to Spiritism*), it doesn't create a new page. It goes back to the existing reincarnation page and adds a section about how this book expands the concept with exegetical arguments from scripture, a moral framework that wasn't in the first book.

By the third book (*Missionaries of the Light*, a spirit narrative), the reincarnation page gains a section about mechanics: spiritual planning committees, the construction of the perispirit, the fertilization process as described by a spirit observer. This isn't in the codification. It's narrative expansion from a completely different genre of writing.

By the time the wiki has processed 36 books that mention reincarnation, the concept page is over 800 lines long, with citations from philosophical treatises, spirit narratives, mediumistic poetry, and historical analyses. It traces how understanding deepens across authors, genres, and decades. No single book contains this view. No search query could assemble it.

The reincarnation page now lists 36 primary sources, each with specific chapter and page references. The charity page cites 58 sources. Mediumship, 32. These aren't just lists. Each source entry comes with a section explaining what that specific book contributes to the concept that the others don't.

Every new book creates dozens of new connections. Not just to the concept pages it directly addresses, but to other books, other entities, other historical periods. The wiki doesn't grow linearly. It grows combinatorially. And you can see it.

## Architecture: Three Layers

The project has two repositories. The content engine (Claude Code reading books, maintaining interlinked Markdown), and a Rails app that serves the wiki as a website.

### Sources (Immutable)

599 books chunked as compressed JSON files. Each chunk has content, page numbers, chapter, section, position, and token count. These files are the raw material. Claude never modifies them.

### Wiki (LLM-Owned)

679 Markdown pages with YAML frontmatter, organized by type: 539 book pages, 58 concept pages, 32 topics, 25 people pages, 14 entity pages, and 8 collection pages. The whole directory is a valid Obsidian vault. Open it in Obsidian and you get graph view, backlinks, and full wikilink navigation for free. No setup required.

The concept pages are the crown jewels. Each covers a doctrinal concept synthesized across every source that touches it. They start with the authoritative definition from the foundational texts, then layer on how the concept expands across narratives, philosophy, and practical guides. Every factual claim cites a specific book, chapter, and location.

### Schema (CLAUDE.md)

This is the constitution. It defines six page types with their frontmatter schemas, the full ingestion workflow, processing order (foundational texts first, then narrative expansions, then secondary authors), filename conventions (no accents, use aliases), and quality checks.

The schema is what makes the output consistent across hundreds of books processed in dozens of sessions over days. Without it, you get entropy: inconsistent formats, missed cross-references, drifting conventions. With it, every session follows the same methodology regardless of context window resets.

## Processing Order Matters

You can't build a knowledge graph randomly. You need the foundational definitions before the narrative expansions.

I processed Kardec's five codification works first. These established authoritative definitions for every core concept. Then the André Luiz series (13 books of spirit narratives expanding the theory with detailed descriptions). Then Emmanuel's historical works, then biographical works, then devotionals.

This ordering meant that when Claude read a narrative about reincarnation mechanics in book #40, the concept page already had a solid definition from book #1. The narrative detail was added as an enrichment, not as the primary source.

Later, the wiki expanded beyond a single author to include European spiritist researchers (Gabriel Delanne, Ernesto Bozzano) and Brazilian philosophers (J. Herculano Pires). Each new author brought a different perspective and writing style, but the concept pages absorbed their contributions the same way: find what's unique, cite it, and connect it to what's already there.

## The Concept Debt Crisis

Halfway through the initial 34 books, I noticed a problem. Claude was creating solid book pages but skipping concept enrichment. Each book got a nice standalone summary, but the concept pages (reincarnation, obsession, mediumship) weren't being updated with citations from new sources. The book pages were islands. The wiki's core value proposition is the connections between them.

I called it out and formalized a post-ingest checklist: every book must update 3-5 concept pages with specific citations. No exceptions. If a book touches reincarnation, the reincarnation page gets a new section with what this specific book adds that the others don't.

Paying down the concept debt from those first 34 books required parallel Claude Code agents, four at a time, each working on different concept pages. The pattern stuck. For the remaining 150 deep reads, concept enrichment was built into the workflow from the start.

## Scaling with Parallel Agents

After proving the pipeline worked with the first 34 books, I scaled it. I downloaded over 500 additional PDFs from multiple sources. The approach shifted from sequential processing to parallel agent batches: up to 13 Claude Code agents running simultaneously in isolated git worktrees, each deep-reading and ingesting its assigned book.

This wasn't without friction. Agents hit rate limits and died mid-read. Some merged conflicting changes to the same concept page. I throttled to 2-3 agents at a time and the throughput stabilized.

183 books were deeply read with full concept enrichment. The remaining books got lighter coverage (book pages with structure and themes, but not the deep cross-referencing). The plan is to keep going.

## The Rails App

The Markdown wiki works great in Obsidian. But I wanted it on the web, searchable, with a knowledge graph you can explore.

I built a Rails 8 app in parallel with the content ingestion. SQLite for everything, Tailwind for styling, deployed with Kamal to [wiki.espirita.club](https://wiki.espirita.club).

### Hybrid Search

Search combines SQLite FTS5 for keyword matching (BM25 relevance scoring, title matches weighted 10x) with vector search via sqlite-vec for semantic similarity. Results merge using Reciprocal Rank Fusion. You can search for a Portuguese term and find concept pages that discuss it under a different name.

### Knowledge Graph

A D3.js force-directed graph renders the entire wiki as a visual network: 679 nodes, over 6,000 edges, color-coded by page type. Zoom, filter by type, click any node to navigate. Each page also has a neighborhood graph showing its immediate connections.

This is where the compounding effect becomes visual. Concept pages sit at the center with dense clusters of connections. Book pages radiate outward, linked to the concepts they address. You can see at a glance which concepts are most deeply covered and which books are most interconnected.

### AI Sprinkles, Not a Chatbot

I originally built a full chat page with RAG-powered Q&A. Then I deleted it. Small AI features sprinkled throughout the wiki turned out to be more useful: an AI summary on every page, enhanced search for question-like queries, deep search across source chunks, contextual Q&A scoped to the current book, passage lookup in concept page sidebars, and concept comparison. Each uses the same vector search + LLM pipeline, scoped to wherever the user already is.

### Content Pipeline

The first version loaded all Markdown files into memory at boot. That caused a stack overflow during Rails initialization. I moved everything to SQLite with a `wiki:sync` rake task that parses frontmatter, renders Markdown, extracts wikilinks as a join table, and builds the FTS5 index. The content engine writes Markdown, the Rails app reads it. Clean separation.

## RAG vs. Wiki

I'm still building the RAG system. It has its uses for answering specific factual questions, finding relevant passages, powering conversational interfaces. But after building the wiki, I see it differently.

RAG retrieves. It finds chunks semantically similar to your question and pastes them into a prompt. The LLM synthesizes an answer on the fly, every time. Ask the same question tomorrow, it does the same work again. Nothing accumulates.

The wiki compiles. It processes each source once, integrates it into a growing structure, and never needs to re-derive that understanding. When you ask "how is reincarnation treated across these 600 books," RAG gives you a handful of relevant chunks from maybe 5-10 books. The wiki gives you an 850-line synthesis across 36 books, with citations to specific chapters and questions.

The difference is like asking a librarian to find relevant passages versus asking a scholar who's read every book in the collection to write a literature review. Both are useful. They're not the same thing.

The wiki also surfaces connections that no query would find. Nobody searches for "how does the description of reincarnation mechanics in a 1945 spirit narrative relate to the exegetical arguments in an 1864 theological treatise." But when Claude reads both books and enriches the same concept page, that connection exists. It's browsable. It compounds with every new source.

## What Domain Experts Think

I built this partly as an experiment. I wasn't sure if people who actually study this material would find it valuable or dismiss it as a shallow imitation.

The reaction from people who've spent years reading these books has been the strongest validation. They're finding cross-references they hadn't made, connections between a concept in a devotional work and a passage in a philosophical treatise from fifty years earlier, traced through the wiki's citations. The wiki isn't replacing their reading. It's making the relationships between what they've read visible.

## The Scholar Model

There's a mental model that made this project click: Claude Code as a scholar, not a search engine.

A search engine takes your query and finds matching documents. A scholar reads deeply, builds understanding over time, and produces work that synthesizes sources into something new. The wiki approach treats the LLM as a scholar.

The scholar reads the entire book, not a sample. Takes notes on what's unique about each source. Goes back to previous work and revises it in light of new reading. Produces citations. The scholar's understanding compounds across sources in a way that retrieval never will.

This only works because of two things: the CLAUDE.md schema (which gives the scholar a consistent methodology across sessions) and the requirement to read everything (which forces grounded output instead of training-data confabulation). Drop either one and you get the garbage I produced on day one.

The wiki keeps growing. Each new author, each new book, each new perspective enriches the existing pages with connections that didn't exist before. It's live at [wiki.espirita.club](https://wiki.espirita.club) if you want to see what an LLM-compiled knowledge graph looks like when it's built from 600 books instead of personal notes.
