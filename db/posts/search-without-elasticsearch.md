Every Rails app eventually needs search. The default instinct is to reach for Elasticsearch, or at least something like pg_search or SQLite FTS5. I built search for [espirita.club](https://espirita.club) using a denormalized table and LIKE queries. It handles ten models, accent-insensitive Portuguese, a Cmd+K modal, and full-page results. No external dependencies, no special database extensions.

Here's how it works and why I didn't need anything fancier.

## The decision

espirita.club is a multi-tenant platform for spiritist organizations. Each center has its own subdomain with activities, events, posts, pages, documents, and more. Users needed to search across all of it.

The content volume per organization is small. A busy center might have a few hundred records total across all models. The entire platform has maybe tens of thousands of searchable records. This is not a scale problem. There's no need for inverted indexes, tokenizers, or a separate search service.

LIKE queries on a regular table are fast enough when your dataset fits comfortably in memory. SQLite doesn't even break a sweat. So instead of configuring FTS5 with custom tokenizers for Portuguese, I went with the simplest thing: a single denormalized table that every searchable model syncs into.

## The search_entries table

The core idea is one table that holds a flattened copy of every searchable record:

```ruby
create_table :search_entries do |t|
  t.references :organization, polymorphic: true, null: false
  t.references :searchable, polymorphic: true, null: false
  t.string :title
  t.text :body
  t.string :normalized_title
  t.text :normalized_body
  t.string :url_path
  t.string :content_type
  t.timestamps
end

add_index :search_entries, [:searchable_type, :searchable_id], unique: true
```

Every searchable record becomes a single row. The polymorphic `searchable` reference points back to the source (an Activity, a Post, whatever). The polymorphic `organization` reference is the tenant. The unique index ensures one entry per source record.

The `normalized_title` and `normalized_body` columns came in a second migration, after I hit the accent problem. More on that soon.

## The Searchable concern

Each model that needs to appear in search results includes a `Searchable` concern:

```ruby
module Searchable
  extend ActiveSupport::Concern

  included do
    has_one :search_entry, as: :searchable, dependent: :destroy
    after_save :sync_search_entry
    after_destroy :remove_search_entry
  end

  def sync_search_entry
    if search_visible?
      upsert_search_entry
    else
      remove_search_entry
    end
  end

  private

  def upsert_search_entry
    entry = search_entry || build_search_entry
    entry.assign_attributes(
      organization: search_organization,
      title: search_title,
      body: search_body,
      url_path: search_url_path,
      content_type: search_content_type
    )
    entry.save!
  end

  def remove_search_entry
    search_entry&.destroy
  end

  def plain_text_from_rich_text(attribute)
    send(attribute)&.to_plain_text
  end
end
```

The concern defines the protocol. Each model implements five methods:

```ruby
class Activity < ApplicationRecord
  include Searchable

  def search_title       = name
  def search_body        = [plain_text_from_rich_text(:description), category&.name, locations].compact.join("\n")
  def search_url_path    = "/activities/#{slug}"
  def search_content_type = "activity"
  def search_organization = center
  def search_visible?    = true
end
```

Posts check `published? && organization.present?` in `search_visible?` so drafts don't leak into results. Each model decides what goes into `search_body`. Activities include their category name and locations. Events include their date and venue. The content is whatever makes sense for that model.

The `after_save` callback keeps the search entry in sync on every write. No background job, no eventual consistency. The record saves, the search entry updates, done.

## The ActionText problem

There's a subtle issue with ActionText. When someone edits an activity's rich-text description, the `Activity` record itself doesn't change. Only the associated `ActionText::RichText` record does. So `Activity`'s `after_save` never fires, and the search entry goes stale.

The fix is an initializer that hooks into ActionText saves:

```ruby
# config/initializers/action_text_search_sync.rb
Rails.application.config.to_prepare do
  ActionText::RichText.class_eval do
    after_save :sync_parent_search_entry

    private

    def sync_parent_search_entry
      record.sync_search_entry if record.respond_to?(:sync_search_entry)
    end
  end
end
```

Without this, every rich-text edit silently leaves the search index stale. It's the kind of bug you don't notice until someone searches for text they just edited and can't find it.

## The query

The `SearchEntry` model handles querying:

```ruby
class SearchEntry < ApplicationRecord
  belongs_to :organization, polymorphic: true
  belongs_to :searchable, polymorphic: true

  before_save :normalize_text

  scope :matching, ->(query) {
    sanitized = "%#{sanitize_sql_like(transliterate(query))}%"
    where("normalized_title LIKE :q OR normalized_body LIKE :q", q: sanitized)
  }

  def self.transliterate(text)
    ActiveSupport::Inflector.transliterate(text.to_s)
  end

  private

  def normalize_text
    self.normalized_title = self.class.transliterate(title)
    self.normalized_body = body.present? ? self.class.transliterate(body) : nil
  end
end
```

The `matching` scope is the entire search engine. Transliterate the query, wrap it in wildcards, run a LIKE against the normalized columns. That's it. No ranking, no relevance scoring, no stemming. Results come back in whatever order the database returns them, which for LIKE queries on SQLite is insertion order.

For the dataset size I'm working with, this is fine. If I needed ranking, I'd add a simple priority based on `content_type` (activities before documents, say) or recency. But nobody has asked for it, so I haven't built it.

## The accent wall

The first version searched against the raw `title` and `body` columns. It worked great until someone searched for "acao" and got no results, even though there were activities with "ação" in the title.

Portuguese is full of diacritics. "ç" for cedilla, tildes on "ã" and "õ", circumflexes on "ê" and "ô", acute accents everywhere. Users type with and without accents depending on their keyboard, their habits, and whether they're on mobile. Search has to handle both.

The solution is `ActiveSupport::Inflector.transliterate`, which strips diacritics using ICU transliteration rules. "ação" becomes "acao", "bebê" becomes "bebe", "programação" becomes "programacao". I apply it at two points:

1. **At index time**: the `before_save` callback writes transliterated text into `normalized_title` and `normalized_body`.
2. **At query time**: the `matching` scope transliterates the user's query before running the LIKE.

Both sides are normalized, so "ação" in the database matches "acao" in the search box, and vice versa. The raw columns stay intact for display. You search the normalized version but show the original.

This took about twenty minutes to implement once I understood the problem. Adding the two normalized columns, writing the callback, updating the scope, and running a rebuild. Compare that to configuring a Portuguese analyzer with stemming rules and stop word lists in Elasticsearch.

## The controller

One controller handles both the Cmd+K modal and full-page search:

```ruby
module Public
  class SearchController < PublicController
    def show
      @query = params[:q].to_s.strip
      @results = current_organization.search_entries
                                     .matching(@query)
                                     .limit(20)

      if request.xhr?
        render partial: "public/search/results",
               locals: { results: @results, query: @query },
               layout: false
      end
    end
  end
end
```

XHR requests (from the modal) get just the results partial. Regular requests get the full page with layout. The `current_organization` scope means cross-tenant results are architecturally impossible. Every query is already filtered to the current subdomain's data.

Ahoy tracking only fires on full-page searches, not on every keystroke in the modal.

## The Cmd+K modal

The search modal uses a native HTML `<dialog>` element and a Stimulus controller:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "input", "results"]
  static values = { url: String }

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
  }

  handleKeydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key === "k") {
      event.preventDefault()
      this.open()
    }
  }

  open() {
    this.dialogTarget.showModal()
    this.inputTarget.focus()
    this.inputTarget.select()
  }

  async search() {
    const query = this.inputTarget.value.trim()
    if (query.length < 2) {
      this.resultsTarget.innerHTML = ""
      return
    }

    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.fetchResults(query), 250)
  }

  async fetchResults(query) {
    const response = await fetch(
      `${this.urlValue}?q=${encodeURIComponent(query)}`,
      { headers: { "X-Requested-With": "XMLHttpRequest" } }
    )
    this.resultsTarget.innerHTML = await response.text()
  }
}
```

Cmd+K opens the dialog. Typing debounces at 250ms, then fetches results via XHR. The response HTML drops straight into the results div. No JSON parsing, no client-side rendering. The server returns the same partial it uses for full-page results.

The dialog lives in the layout so it's available on every page:

```erb
<body data-controller="search-modal"
      data-search-modal-url-value="<%= search_path %>">
  <!-- ... -->
  <%= render "layouts/search_modal" %>
</body>
```

## Highlighting on destination pages

When a user clicks a search result, the link includes `?q=<query>` in the URL. A separate Stimulus controller on the destination page picks that up:

```javascript
connect() {
  const query = new URLSearchParams(window.location.search).get("q")
  if (!query) return

  this.highlightMatches(query)
  history.replaceState(null, "", window.location.pathname)
}
```

It walks the DOM tree, finds text nodes matching the query, wraps them in `<mark>` elements, and scrolls the first match into view. Then it cleans the `?q` parameter from the URL via `replaceState` so the browser history stays clean.

This is entirely client-side. The server doesn't know about the highlighting. It just renders the page normally.

## The rebuild task

For recovery or after schema changes, a rake task rebuilds the entire index:

```ruby
namespace :search do
  task rebuild: :environment do
    SearchEntry.delete_all

    searchable_classes = [Center, Federation, Activity, Event,
                          Page, Document, MembershipPlan, AssociationProgram]

    searchable_classes.each do |klass|
      count = 0
      klass.find_each do |record|
        record.sync_search_entry
        count += 1
      end
      puts "Indexed #{count} #{klass.name.pluralize}"
    end

    puts "Total search entries: #{SearchEntry.count}"
  end
end
```

`find_each` processes records in batches. `sync_search_entry` respects `search_visible?`, so draft posts and unpublished content get skipped automatically. I've run this exactly twice: once after adding the normalized columns, and once after expanding what activities include in their search body.

## Snippets

Search results show a snippet of the matching text. The `SearchEntry` model handles extraction:

```ruby
def snippet_for(query)
  return nil if body.blank?

  normalized_query = self.class.transliterate(query.to_s.downcase)
  normalized = self.class.transliterate(body.downcase)
  index = normalized.index(normalized_query)

  return body.truncate(160) unless index

  start = [index - 80, 0].max
  stop = [index + normalized_query.length + 80, body.length].min
  snippet = body[start...stop]
  snippet = "...#{snippet}" if start > 0
  snippet = "#{snippet}..." if stop < body.length
  snippet
end
```

The search for the match position runs against the normalized text, but the snippet itself comes from the raw text. So if the user searches "acao", the snippet shows "...programação espiritual e ação social..." with the original accents intact.

## When you should reach for something else

This approach works because of a few specific conditions:

**Small dataset per query scope.** Each organization has hundreds of records, not millions. LIKE queries with leading wildcards can't use indexes, so they scan the entire scope. At thousands of rows, that's microseconds. At millions, it's a problem.

**No ranking requirements.** Results come back unranked. If users expect Google-style relevance ordering, you need TF-IDF or BM25, which means FTS5 or a dedicated search engine.

**No fuzzy matching.** LIKE is exact substring matching (after transliteration). "activty" won't match "activity". If you need typo tolerance, you need trigram indexes or a search service with fuzzy support.

**Simple tokenization needs.** I'm matching substrings, not words. Searching "prog" matches "programação". For some apps that's a feature. For others, you'd want word-boundary matching, which LIKE doesn't do well.

If any of these conditions change, the upgrade path is clear. The `SearchEntry` table stays. The `Searchable` concern stays. The sync callbacks stay. You swap the `matching` scope from LIKE to FTS5 or plug in a search service that reads from the same table. The denormalized architecture is the hard part, and it's already done.

For now, LIKE works. It's been in production for weeks, search is fast, users find what they need, and there's exactly zero infrastructure to maintain. Sometimes the boring solution is the right one.
