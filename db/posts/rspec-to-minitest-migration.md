I've been using RSpec on the BSPK codebase for about eight years. It was already there when I joined, and over time we accumulated the usual entourage: FactoryBot, shoulda-matchers, rswag, pundit-matchers, rspec-sidekiq, rspec-json_expectations. The test suite worked fine. It caught bugs. CI was green more often than not.

But something had been bothering me for a while.

Every time I opened a spec file, I had to mentally parse a DSL before I could think about the actual behavior being tested. `let` blocks scattered across nested `context` groups. `subject` redefined three levels deep. Shared examples that saved typing but hid what was actually being asserted. The tests were correct, but they weren't *clear*.

And then there were the factories. Our FactoryBot setup had grown into its own little universe, traits and sequences and transient attributes building objects that looked increasingly different from the data in production. Every time a test failed, the first question was always: is this a real bug, or did the factory build something that would never actually exist?

We'd recently finished upgrading to Ruby 4 and Rails 8.1, and the codebase felt fresh. It seemed like the right moment. Not a gradual deprecation. A full migration. RSpec to Minitest, FactoryBot to fixtures, all of it.

It took five days.

## The approach

I didn't want a big bang rewrite where everything breaks at once and you spend two weeks debugging test infrastructure instead of shipping features. So I set up Minitest alongside RSpec, both frameworks running in CI simultaneously, and migrated in phases.

The plan was simple: start at the edges of the codebase (lib specs, validators, helpers), work inward toward the core (models, services, jobs), and finish with the integration layer. Each phase would be a self-contained commit. If something went wrong, I could revert a single phase without touching the rest.

Phase 1 was just infrastructure. A `test_helper.rb`, support modules to replace the RSpec ecosystem (auth helpers, Elasticsearch setup, WebMock stubs, VCR config, custom assertions), and a starter set of YAML fixtures. Nothing migrated yet, just laying the foundation.

## Moving through the codebase

Phases 2 and 3 knocked out the easy stuff: validators, routing specs, helpers, forms, mailers, and all the lib specs. These were the simplest conversions because they mostly tested pure Ruby objects with minimal database interaction. The RSpec DSL peeled off cleanly. `describe`/`it` became `def test_`, `let` became local variables or `setup` blocks, `expect(x).to eq(y)` became `assert_equal y, x`.

Phase 3.5 was where things got interesting. I exported a curated dataset from our development environment into YAML fixtures, covering about two dozen tables. This wasn't a dump of everything. I picked specific records that represented real data relationships: a company with stores, sales associates, shoppers, appointments, items, lists. Named fixtures with meaningful identifiers instead of `:one` and `:two`.

This ended up being one of the most valuable parts of the whole migration. More on that in a follow-up post.

Phases 4 through 9 were the bulk: agent tools, data import pipeline, rake tasks, finders, services, and jobs. Hundreds of test files, each one a small translation exercise. Most conversions were mechanical, but finders needed special attention because they hit Elasticsearch. I built an `ElasticsearchTestHelper` with a `safe_reindex` method that ensured indexes were fresh before each test without blowing up parallel workers.

Phase 10 was models, all 171 of them. This was also where I made a discovery about parallel testing that changed the whole trajectory of the project.

## The parallel testing surprise

When I first set up Minitest, I copied a pattern from some of the existing specs: `parallelize(workers: 1)`. Several spec files had disabled parallel execution because of fixture isolation issues, and I carried that forward without questioning it.

During Phase 10, I realized this was unnecessary. Minitest's parallel testing gives each worker its own database. Fixtures load into each worker's DB independently. There's no cross-contamination. I removed the `parallelize(workers: 1)` overrides from hundreds of test files and let the suite run with all available processors.

The test suite went from around 400 seconds to 82 seconds. Twelve parallel processes, nearly a 5x speedup, from removing a line of code.

The irony is that this was always available in theory, but with RSpec and FactoryBot, we'd never been able to use it cleanly. Factories create data at runtime, and the interactions between parallel processes creating overlapping records had been a constant source of flaky tests. Fixtures, loaded once per worker into isolated databases, just worked.

## Replacing the ecosystem

One thing I underestimated going in was how much of our test infrastructure was actually just wrappers around RSpec plugins. shoulda-matchers gave us one-liner association and validation tests. Replacing those took about an hour: two small modules (`AssociationAssertions` and `ValidationAssertions`) with methods like `assert_belongs_to` and `assert_validates_presence_of` that checked the actual ActiveRecord reflections and validators. Same coverage, no gem dependency, and I could see exactly what was being tested.

Pundit matchers were even simpler. A Pundit policy is just a Ruby object with methods that return booleans. `assert policy.show?` reads better than `it { is_expected.to permit(:show) }`.

The rswag migration was the biggest surprise. We had over 120 integration specs using rswag's DSL to generate OpenAPI documentation from tests. The DSL was verbose: `path`, `get`, `response`, `run_test!` blocks nested three levels deep. I stripped all of it and replaced it with plain Minitest integration tests using the `committee` gem for schema validation. Instead of generating OpenAPI docs from tests, we now validate tests against hand-written OpenAPI specs. Schema-first instead of test-first.

This turned out to be a strict upgrade. The OpenAPI specs are now the source of truth, they live in version control, and every integration test validates its response against the schema automatically. If the API drifts from the spec, the test fails.

## The fixture question

I know fixtures are controversial. The Rails community spent years moving away from them toward FactoryBot, and for understandable reasons: early fixture setups were often a mess of tangled YAML files where changing one record broke twenty tests.

The key difference this time was being intentional about fixture design. Instead of generating a fixture for every model and hoping for the best, I curated a dataset that represents a real slice of the application. A company called "vista" with two stores, each with sales associates, shoppers, appointments, and items. Every fixture has a meaningful name. Every relationship makes sense.

The result is that when I read a test, I know exactly what data it's working with. `shoppers(:maria)` is a shopper at the "downtown" store. `items(:silk_scarf)` is a product in vista's catalog. No factory magic, no traits, no transient attributes. Just data that looks like what's actually in the database.

I'm planning a dedicated post on fixture design because I think it's the thing most people get wrong, and it's the reason fixtures got a bad reputation in the first place.

## Phase 17: deleting RSpec

The final phase was the most satisfying. Remove rspec-rails and every plugin that depended on it. Delete the `.rspec` config. Remove the RSpec configuration from `application.rb`. Update CI to run `rails test` instead of `rspec`.

Twelve gems removed in one commit. The Gemfile got noticeably shorter. Boot time dropped. The test infrastructure went from a sprawl of DSL-specific configuration to twenty focused Ruby modules that I could read top to bottom.

## After the merge

The migration landed on a Friday. The following week was cleanup: fixing a few tests that had been added on other branches while the migration was in flight, adding JUnit reporting for CircleCI's test summary UI, fixing Ruby 4 deprecation warnings that had been hiding under the RSpec output.

I also used the momentum to add coverage that hadn't existed before. With fixtures and a clean test infrastructure, writing new tests was fast enough that I added a couple hundred tests for models and concerns that had been under-tested. When writing a test takes thirty seconds instead of two minutes of factory setup, you write more tests.

The `committee` integration also expanded. By the end of the week, all 125 integration test files validated their responses against OpenAPI schemas. Every API endpoint now has a contract test whether we planned it that way or not.

## The side effects

The speed improvement was the most obvious win, but two other things changed that I didn't fully anticipate.

The flaky tests almost completely disappeared. Our RSpec suite had a handful of tests that failed randomly, often enough that we'd added CI retry logic to mask it. Most of the flakiness came from factories creating records that collided across parallel processes, or from test order dependencies hidden by RSpec's lazy `let` evaluation. With fixtures loaded once into isolated per-worker databases and no lazy evaluation hiding state, the randomness just stopped. We removed the CI retry config within a week.

The other surprise was how much better Claude Code handles Minitest. I use Claude Code for most of my development work, and it writes Minitest tests noticeably better than it wrote RSpec. That makes sense if you think about it: Minitest tests are just Ruby methods with assertions. There's no DSL to get wrong, no `let`/`subject`/`shared_examples` nesting to misuse, no factory traits to hallucinate. When I ask Claude to add test coverage for a new feature, the output is correct on the first try far more often than it was with RSpec. The tests it generates look like tests I'd write myself, which was rarely true with the RSpec output.

## The numbers

Before the migration: a slow, serial test suite with heavy boot time, about a dozen testing gems, and factories that were their own maintenance burden.

After: the suite runs in under 90 seconds on twelve parallel workers. Thirty YAML fixture files with curated data. Twenty support modules, all plain Ruby. Zero RSpec dependencies. Tests that are less flaky, easier for both humans and AI to write, and read like what they are: assertions about behavior.

## What's coming next

This post covers the full arc, but there's a lot more to dig into. Over the next couple of weeks I'll write about:

**[Fixture design for real applications.](/blog/fixtures-for-real-rails-apps)** How to structure YAML fixtures for a multi-tenant codebase with complex associations, and why most fixture setups fail.

**[Parallel test isolation with Elasticsearch.](/blog/parallel-testing-elasticsearch-rails)** The specific challenges of running search-heavy tests across multiple workers, and the `safe_reindex` pattern that made it reliable.

If you're thinking about making this switch, the short version is: it's less scary than it looks, and the payoff is real. The five days of migration work have already paid for themselves in faster CI, simpler debugging, and tests that are genuinely easier to read and write.
