This is the third post in a series about [migrating a large Rails app from RSpec to Minitest](/blog/rspec-to-minitest-migration). The [second post](/blog/fixtures-for-real-rails-apps) covered fixture design. This one is about the hardest part of the whole migration: making Elasticsearch tests run in parallel.

BSPK has a lot of search. Shoppers, items, notes, tags, feed posts, sales associates. Most of these are backed by Elasticsearch via Searchkick, and they all had specs that indexed data and asserted on search results. When the test suite ran serially, this worked fine. Every test had the index to itself. When I turned on parallel testing with twelve workers, everything broke.

## The problem

Minitest's parallel testing gives each worker its own database. Fixtures load into each worker's DB independently, transactions roll back between tests, and there's no cross-contamination. But Elasticsearch isn't a database. It's a shared external service. All twelve workers were hitting the same ES cluster, writing to the same indexes, and reading each other's data.

A test in worker 3 would index five shoppers and assert that a search returned exactly five results. Meanwhile, worker 7 had just indexed its own shoppers into the same index. The search returned twelve results. Test fails.

The flakiness was maddening because it was timing-dependent. Run the suite once, three failures. Run it again, different failures. Run it a third time, all green. Classic parallel race condition.

## Per-worker index prefixes

The fix was straightforward once I understood the problem. Each parallel worker gets its own Elasticsearch index prefix, so their data never overlaps.

In `test_helper.rb`:

```ruby
ENV["SEARCHKICK_INDEX_PREFIX"] = "test#{ENV.fetch('TEST_ENV_NUMBER', nil)}"

parallelize(workers: :number_of_processors)

parallelize_setup do |worker|
  ENV["SEARCHKICK_INDEX_PREFIX"] = "test#{worker}"
  Searchkick.index_prefix = "test#{worker}"

  # Clear cached index objects so models pick up the new prefix
  Searchkick.models.each do |model|
    model.instance_variable_set(:@searchkick_index, nil)
  end
end
```

Worker 0 writes to `test0_shoppers`, worker 1 writes to `test1_shoppers`, and so on. Same isolation model as the per-worker databases, just applied to Elasticsearch.

The cache clearing is important. Searchkick memoizes the index object on each model class. Without clearing it, the model would keep using the prefix from before the fork, and you'd be right back to shared indexes.

## Disabling callbacks globally

Searchkick hooks into ActiveRecord callbacks to automatically index records on create, update, and destroy. That's great in production, but in tests it means every fixture load triggers an ES index operation. With thirty fixture files loading into twelve workers simultaneously, that's a lot of unnecessary indexing.

I disabled callbacks globally in `test_helper.rb`:

```ruby
Searchkick.disable_callbacks
```

Tests that need search behavior opt in explicitly:

```ruby
def with_searchkick(&block)
  Searchkick.callbacks(true, &block)
end
```

This way, a model test that checks validations never touches Elasticsearch. Only the tests that actually exercise search pay the indexing cost.

## The safe_reindex pattern

Every search test needs to get data into ES before it can assert on results. The naive approach is to call `Model.reindex` and hope for the best. In parallel, "hope for the best" fails about 30% of the time.

The pattern I landed on:

```ruby
module ElasticsearchTestHelper
  def safe_reindex(model_class)
    model_class.instance_variable_set(:@searchkick_index, nil)
    model_class.reindex(async: false, mode: :inline, refresh: false)
    model_class.instance_variable_set(:@searchkick_index, nil)
  end

  def with_searchkick(&block)
    Searchkick.callbacks(true, &block)
  end
end
```

Two things to note. First, the `@searchkick_index` cache is cleared both before and after the reindex. Before, so that Searchkick creates a fresh timestamped index with the current worker's prefix. After, so that subsequent calls see the new index name (Searchkick appends a timestamp to each reindex).

Second, there's no `index.delete` call. An earlier version had one:

```ruby
index = model_class.searchkick_index
index.delete if index.exists?
model_class.reindex(...)
```

This caused intermittent 404 errors under parallel load. The problem was a race condition: Searchkick's `reindex` already creates a new timestamped index, imports data, swaps the alias, and cleans up old indexes. The explicit delete before reindex was redundant, and under high concurrency, the delete would sometimes hit right as another operation was reading the alias. Removing it fixed the last source of flaky ES failures.

I verified this with five consecutive full suite runs: 7,500+ tests each, zero failures.

## The clean-room company

The [fixture design post](/blog/fixtures-for-real-rails-apps) mentioned a three-company structure: Vista (primary data), Art Gallery (cross-tenant), and ES Test (clean-room). The clean-room company exists specifically for search tests.

```yaml
# Clean-room company for Elasticsearch tests — has NO shoppers,
# store_visits, chats, or other records so safe_reindex produces
# a known-empty baseline.
es_test:
  name: ES Test Company
  dns_names: "{es-test.bspk.com}"
  external_id_str: es_test_company
  abbreviated_name: ES
```

With matching fixtures for a store, two sales associates, and their accounts. All accessible through helpers:

```ruby
def es_company = companies(:es_test)
def es_store   = stores(:es_test_store)
def es_sa1     = sales_associates(:es_test_sa1)
def es_sa2     = sales_associates(:es_test_sa2)
```

When a search test starts, it calls `safe_reindex` on the relevant model class. Because the ES Test company has zero child records in fixtures, the initial index is empty. The test then creates exactly the records it needs using inline factory helpers, re-indexes, and asserts on known data.

No surprise records from other fixtures. No bleeding from other tests. The test controls the entire search state.

## before_all for expensive setup

Some search test classes have heavy setup: creating dozens of records with specific attributes, then reindexing. The shopper finder tests, for example, create shoppers with different names, emails, phone formats, gender values, and contact preferences to exercise every search filter.

Running that setup before every test method was adding up. Six test classes were taking three times longer than they needed to because the same twenty records were being created and indexed sixty times.

TestProf's `before_all` runs setup once per test class and wraps it in a transaction that persists across all test methods:

```ruby
class ShoppersFinderTest < ActiveSupport::TestCase
  include ElasticsearchTestHelper
  include InlineFactoryHelpers
  include BeforeAll

  before_all(setup_fixtures: true) do
    @company = es_company
    @sa = es_sa1

    @shopper1 = create_shopper(company: @company, store: es_store,
      first_name: "Alice", last_name: "Smith", email: "alice@example.com")
    @shopper2 = create_shopper(company: @company, store: es_store,
      first_name: "Bob", last_name: "Jones", phone: "+15551234567")
    # ... 15 more shoppers with specific attributes

    safe_reindex(ElasticSearch::SearchClient)
  end

  setup do
    @company.reload  # reset any mutations from previous test
  end

  def test_search_by_name
    results = SalesAssociate::ShoppersFinder.new(@sa, query: "Alice").results
    assert_includes results, @shopper1
    refute_includes results, @shopper2
  end
end
```

The `setup_fixtures: true` flag is required in Rails 8 to make fixture data available inside the `before_all` block. The `setup` block calls `.reload` on objects that tests might have mutated (changing a filter, updating an attribute) so each test sees fresh state.

The `before_all_helper.rb` also patches Minitest to deactivate the previous class's transaction when switching between test classes in a parallel worker. Without this, the transaction from one `before_all` class could leak into the next class running in the same worker:

```ruby
Minitest.singleton_class.prepend(Module.new do
  def run_one_method(klass, method_name)
    prev = defined?(@previous_klass) ? @previous_klass : nil
    if prev && prev != klass && prev.respond_to?(:before_all_executor)
      prev.before_all_executor&.deactivate!
    end
    @previous_klass = klass
    super
  end
end)
```

This was a fun one to debug. Tests would pass in isolation, pass when running a single file, but fail when running the full suite because an unrelated test class's `before_all` transaction was still open.

## VCR and the body matching problem

Some of our search-adjacent code calls LLMs (the natural language search feature translates English queries into Elasticsearch DSL). These HTTP calls are recorded with VCR cassettes. When we went parallel, the cassettes stopped matching.

The issue: VCR matches requests by method, URI, and body. The request body includes the system prompt, which includes the full site content (for the AI chat agent). Every time a blog post changed or a new record was added, the body changed, and the cassette didn't match.

On top of that, Elasticsearch index names in the request body now included worker-specific prefixes (`test0_shoppers` vs `test1_shoppers`), so the same test recorded on worker 0 wouldn't match when replayed on worker 3.

The fix was a custom request matcher that normalizes both problems:

```ruby
VCR.configure do |c|
  c.register_request_matcher :normalized_body do |request_1, request_2|
    normalize = ->(body) {
      return body if body.nil? || body.empty?
      normalized = body.dup
      # Strip worker-specific ES index prefixes
      normalized.gsub!(VCR_INDEX_PREFIX_PATTERN, VCR_NORMALIZED_INDEX_NAME)
      # Strip LLM system prompts that change with content updates
      normalized.gsub!(/"role"\s*:\s*"(system|developer)".*?(?="role")/, "")
      normalized
    }
    normalize.call(request_1.body) == normalize.call(request_2.body)
  end
end
```

Cassettes are now recorded with normalized bodies, and replayed with the same normalization. The index prefix `test3_shoppers` in a live request matches `test_shoppers` in the cassette. The system prompt with yesterday's blog posts matches the cassette from last week.

## The parallelize(workers: 1) trap

The most expensive mistake I made was a subtle one. During the initial migration of finder specs (Phase 7), I added `parallelize(workers: 1)` to every ES-backed test class. My reasoning: these tests are fragile, let's run them serially to avoid issues.

What I didn't realize is that Rails' parallelization is all-or-nothing at the suite level. If *any* test class sets `parallelize(workers: 1)`, Rails falls back to running the *entire suite* in a single process. Not just that class. Everything.

The suite was running in about 400 seconds. I assumed that was normal for the volume of tests. When I removed all the `parallelize(workers: 1)` overrides and let Rails use all twelve cores, it dropped to 82 seconds. I'd been running the full suite serially for three days without realizing it.

The lesson was simple: don't use `parallelize(workers: 1)` on individual classes. Either fix the parallel isolation issue, or if you really need serial execution, use a different mechanism (like TestProf's `before_all` to reduce per-test cost).

## The final numbers

After all the ES parallel work landed, the search test files went from being the slowest, flakiest part of the suite to being unremarkable. Fifty-six test files with ES integration, running across twelve parallel workers, consistently green.

The standardization commit that applied `safe_reindex` across all fifty-six files actually *removed* about 180 lines of code. The previous patterns (manual delete + reindex, inline callbacks blocks, redundant refresh calls) were all more code *and* less reliable.

For the six heaviest test classes, `before_all` cut execution time by roughly 3x. Those classes have a hundred-plus test methods each, and the setup (creating records + reindexing) only runs once.

If you're running Elasticsearch tests in a Rails app and they're either slow or flaky, the playbook is: per-worker index prefixes, globally disabled callbacks with opt-in, a clean-room fixture company with zero indexed records, `safe_reindex` without explicit deletes, and `before_all` for the expensive test classes. Every piece solves a specific problem. Skip one and you'll probably find out which one the hard way.
