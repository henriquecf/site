My kid keeps asking me about Toy Story. Specifically, about Andy's dad. Where is he? Why don't you ever see him? Is he dead?

I told him I'd write him a book about it.

I knew there were fan theories out there, but I didn't know any of them well enough to write something honest. So before the book, I'd need to actually learn the material. And I'd just spent a month [building an LLM wiki](/blog/karpathy-llm-wiki-claude-code) on a completely unrelated topic. The pattern was sitting right there.

So I pointed Claude Code at the Toy Story 0 mythology and built a second wiki.

This post is about what changed and what stayed the same.

## The corpus

The first wiki was hundreds of books from a single tradition, all long-form text chunked from PDFs.

The Toy Story corpus looks nothing like that. There's a couple dozen YouTube videos (Super Carlin Brothers, Mike Mozart's two-hour livestream, a few others), two dozen articles in English and Portuguese, some forum posts, a handful of tweets. Most of the videos are an hour-plus of two people talking with each other, which means the YouTube transcripts are the densest and most contradictory part of the source material.

That mismatch matters. A 19th-century treatise on reincarnation has a thesis, a structure, and arguments. A two-hour rambling YouTube livestream has facts buried in tangents and three different versions of the same scene depending on what minute you're listening to. Same Karpathy LLM Wiki pattern, but the schema had to handle it.

## What stayed the same

Three layers, identical to the first wiki:

1. `raw/` — every source captured in its original form, never edited. YouTube transcripts go in as VTT plus a cleaned-up Markdown version. Articles get pulled into Markdown with the URL preserved. Tweets get screenshotted text. Once captured, none of this gets touched.
2. `wiki/` — the LLM-owned layer, in Portuguese (the kid reads Portuguese, not English, and the sources are mixed languages anyway). Pages have YAML frontmatter, wikilinks, citations into `raw/`.
3. `CLAUDE.md` — the schema. Page types, citation format, language rules, ingestion workflow, lint checks.

The schema is the part that does the heavy lifting. Every session I run, no matter how long ago the previous one was, follows the same conventions because they're written down and Claude reads them first.

The "read everything" rule from the spiritist wiki carried over. I had to write it as an explicit note in CLAUDE.md, otherwise the agent skims and writes confident, generic prose from training data instead of grounded summaries from the actual sources. Nothing about that has changed in the past month.

## What changed

Three things, and all of them mattered more than I expected.

### Citation format for mixed sources

A book citation can be `[^kardec-le-q166]`: author, work, question number. A YouTube citation needs a timestamp, because the source is two hours long and a claim made at minute 4 has different weight than a claim made during a tangent at minute 95. So the schema defines `[^scb-bbmzuoBC1Rs@04:12]`: source slug, video ID, timestamp. Article slugs, tweet IDs, and forum post URLs each get their own conventions. Every claim in the wiki points to a specific second of a specific source.

### Theories as first-class pages

The spiritist wiki had concept pages and book pages. The Toy Story wiki has those too, but it also has a `teorias/` directory. Each fan theory is a page with a `canon: fan-theory | debunked | speculation | meta` frontmatter field. There's a comparison matrix page that lays out the competing theories side by side: Mike Mozart's polio version, Jon Negroni's divorce version, Andrew Stanton's official "complete and utter fake news" debunk, plus a few weaker ones. When two theories contradict each other, the wiki tracks both with citations and marks one as ADOPTED.

I picked Mozart's. His version makes way more sense to me. Joe Ranft, one of Pixar's original story guys, told it to him in person, and the visual evidence (cowboy decoration in the house, the mother saying "I knew this would happen one day," the way Andy inherits Woody at the deathbed) lines up with a polio death story from the 1950s. Negroni's divorce theory was reverse-engineered from a Buzz-as-stepfather metaphor that Stanton himself called nonsense. I kept Negroni's theory in the wiki, because it's part of the cultural history of these fan theories, but I marked it "historical context, not adopted" and removed the evidence reinterpretations from the main entity pages.

That kind of editorial position is something a wiki can do that RAG can't. Retrieval finds chunks that match your query. It can't tell you "this claim is contested" or "this source is a debunk of that other source." The wiki makes those relationships explicit.

### Source errors get pinned, not silently absorbed

One Brazilian article (Omelete) said Andy's father married Molly. Molly is Andy's younger sister, not his mother. I caught it on the first read and the wiki now has a warning on the relevant page: "⚠ erro em Omelete: Molly é filha, não esposa." If I ever come back and re-ingest that article, the same warning is there. The error is tracked, not corrected by deletion. Anyone reading the wiki can see that one source got it wrong, what the right answer is, and which other sources contradict it.

## The three things that surprised me

I had built a wiki before. I knew the pattern would work. What I didn't know was how the second one would feel different.

### Connections I didn't see coming

The most striking moment was Emma Jean. The wiki had a page for Andy's paternal grandmother, initially unnamed. Fan theories called her "the grandmother" or "the woman in the photographs." Then I ingested a Super Carlin Brothers video about Al's Toy Barn, and one of the brothers mentioned a postcard visible in two different Pixar movies: in Andy's house in *Toy Story*, and on Carl Fredricksen's mantel in *Up*. Same postcard. Same handwriting. Signed "Emma Jean."

Pete Docter, the *Up* director, has confirmed that Emma Jean was a friend of Carl's from before he met Ellie. Same postcard, same handwriting, signed "Emma Jean." The wiki linked the two films through a single character that nobody had a page for. I didn't ask Claude to make that connection. It emerged when the same name showed up in two source files and the entity page got created to hold it.

This kind of cross-source link happens because the LLM is reading every source and updating an existing graph. RAG would have surfaced one of those mentions to one of my queries. It wouldn't have made the connection.

### The LLM composes, doesn't just collect

The Toy Story wiki has a page on Al McWhiggin, the toy collector from *Toy Story 2*. Most of what's on that page didn't exist in any single source.

The page is composed from fragments across half a dozen sources: Al's mother dying when he was young, his father running a farm, a childhood story about him trying to steal Andy's father's Woody, a parallel Mike Mozart draws between himself and Al as compulsive collectors who both lost a parent young. The Al page synthesizes all of that into a coherent backstory: only child, raised on a farm, mother died when he was young, father compensated by indulging him with toys, grew up obsessed with collecting, eventually tried to acquire the rare Woody he'd coveted as a kid.

No single source contains that paragraph. The wiki composed it from fragments across half a dozen sources, with citations pointing to which fact came from where. Reading the page, you can trace any claim back to the second of the YouTube video it came from.

I never wrote a prompt that said "compose a backstory for Al." I gave the schema, the citation rules, and the read-everything rule, and the composition emerged.

### Structured data unlocks the next step

This is the surprise I want to dwell on, because it's the reason the book exists.

A wiki page with consistent frontmatter, citations to specific timestamps, explicit relationships, and a canon field is structured data. Once the wiki was solid, writing the book got easier in ways I hadn't predicted.

I asked Claude for chapter outlines. It pulled from the events directory and ordered them chronologically: the cereal letter in the late 1950s, the polio diagnosis, the surviving toys, the move to Seattle, the marriage, Andy's birth, the death, the inheritance. The events all had dates in their frontmatter, so the ordering was deterministic.

I asked for a list of every visual detail that would need to be illustrated. Claude pulled from the conceitos directory: cowboy decoration in the house, the backwards N on Woody's boot, the photographs in Andy's room that were really his father's, the chest in the attic, Hidden City Cafe. Each one with a citation to where the detail came from, so I could verify before drawing.

I asked for chapters in the voice of a children's book in Portuguese, grounded in the Mozart theory and avoiding any of the rejected theories. The wiki's `canon` field made this filterable: only adopt facts from pages marked as adopted in the matrix; ignore `canon: debunked` and `canon: speculation` content. The drafts came back grounded.

By the time I was generating illustrations with Stitch, the prompts I was giving were almost copy-paste from the wiki entity pages. "Andy's father, around eight years old, in a 1950s American kitchen, holding a Woody doll, with cowboy-themed wallpaper in the background." Every visual element traced back to a specific source.

The book is in EPUB beta now, with images. He has it. There's probably a second story coming from the same wiki, maybe about Mr. Potato Head's family or one of the other characters with a hinted-at backstory. I haven't decided yet.

## Two wikis later

The two projects look nothing alike. The first is hundreds of books of religious doctrine compiled into a public reference site for adults. The second is a few dozen videos and articles about a Pixar fan theory, compiled into research material for a children's book aimed at one specific reader. The sources, languages, and scales have nothing in common.

What survives is the schema and the discipline of reading every source.

I think the LLM Wiki pattern is going to get used in places I haven't thought of yet. The two cases I have so far don't have much in common except those two things. That's probably the part that matters.

Last week he asked me what really happened to the old space ranger toy that Buzz replaced. There's no page on that yet.
