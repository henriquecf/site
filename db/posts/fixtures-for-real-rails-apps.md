In the [first post of this series](/blog/rspec-to-minitest-migration), I described migrating BSPK's entire test suite from RSpec and FactoryBot to Minitest and fixtures. Five days, seventeen phases, and a 5x speedup in CI. But I glossed over the part that took the most thought: designing the fixtures themselves.

Fixtures have a bad reputation, and I get it. Most fixture setups I've seen are terrible. Auto-generated YAML files with records named `:one` and `:two`, no coherent relationships between them, and a vague sense that touching any fixture will break something somewhere. Developers reach for FactoryBot because it feels safer to build fresh objects from scratch than to navigate a minefield of shared state.

The problem was never fixtures. It was how people designed them.

## Start from real data

The first thing I did was *not* write fixtures by hand. I wrote an export script that pulled a curated subset from our development environment. I picked a single company (Vista, one of our dev tenants) and followed its relationships: stores, sales associates, shoppers, items, appointments, lists, tasks. The script sanitized emails to `@example.com`, stripped sensitive fields, and generated YAML using Rails' association label format.

This is the part most people skip. They either hand-write fixtures that look nothing like their actual data, or they let Rails scaffold generic ones. Both approaches fail the same way: the test data doesn't represent reality, so the tests don't catch real bugs.

Starting from a real dataset gave me fixtures that had the right shape. Real associations, real cardinalities, real edge cases that existed because actual users had created them. Shoppers with multiple addresses. Appointments across different stores. Sales associates with varying permission levels. I didn't have to invent these scenarios; they were already in the data.

The export script was about a thousand lines, which sounds like a lot. Most of it was selecting which records to include and handling association labels correctly. It ran once, generated the YAML, and hasn't been touched since. That's the right ratio for infrastructure code: invest upfront, then forget about it.

## Name things like they matter

This is the difference between fixtures that help you and fixtures that haunt you:

```yaml
# Bad: what is :one? Why does this test use it?
one:
  first_name: MyString
  last_name: MyString
  email: MyString
  company: one

# Good: I know exactly who this is
russell_winfield:
  first_name: Russell
  last_name: Winfield
  email: russell.winfield@example.com
  gender: 0
  company: vista
  store: los_angeles
```

Every fixture in our suite has a name that means something. `shoppers(:russell_winfield)` is a male shopper at the LA store. `sales_associates(:jen_wilson)` is the manager. `stores(:saint_honore)` is the Paris location. When I read a test that references these, I know immediately what data it's working with.

We went further and built a `FixtureHelpers` module that adds semantic aliases:

```ruby
module FixtureHelpers
  def vista_company    = companies(:vista)
  def la_store         = stores(:los_angeles)
  def manager_sa       = sales_associates(:jen_wilson)  # Manager of all stores, LA
  def senior_sa        = sales_associates(:yana_bets)   # Senior SA, LA
  def regular_sa       = sales_associates(:yauhen_hatsukou) # Regular SA, LA
  def paris_sa         = sales_associates(:jimmy_shan)  # SA, Saint-Honoré
  def male_shopper     = shoppers(:russell_winfield)    # gender: 0, phone + email
  def female_shopper   = shoppers(:maria_johnson)       # gender: 1, phone + whatsapp
end
```

The role comments matter. Six months from now, when someone needs a shopper with WhatsApp enabled, they scan the helpers and find `female_shopper` with its comment. No grepping through factory traits. No guessing.

## Design for multi-tenancy

BSPK is a multi-tenant app. Every query is scoped to a company. This means test data needs to reflect that boundary, or you'll write tests that accidentally pass because they're pulling records from the wrong tenant.

The fixture dataset has three companies:

**Vista** is the primary tenant. Most test data lives here: five stores across two regions, a dozen sales associates, fifty-plus shoppers, items, appointments, lists, tasks. When a test needs "a normal scenario," it uses Vista data.

**Art Gallery Demo** is the cross-tenant company. It has its own store, its own sales associates, its own shoppers. Any test that verifies tenant isolation creates data in Vista and asserts it doesn't leak into Art Gallery (or vice versa). Having a second tenant in fixtures makes these tests trivial to write.

**ES Test** is the clean-room company. Zero child records. It exists specifically for Elasticsearch tests that need a known-empty baseline before indexing test-specific data. More on this in the next post about parallel testing.

This three-company structure wasn't in the original export. I added it after the first few phases of migration, when I realized that single-tenant fixtures would leave a whole class of bugs uncovered.

## Edge cases go at the bottom

The exported fixtures represent the happy path: real data, real relationships, everything working as expected. But tests also need edge cases. Deleted records, missing contact info, unusual gender values, opt-out flags.

I added these as synthetic fixtures at the bottom of the relevant files:

```yaml
# --- Synthetic edge-case fixtures (not from export) ---

deleted_shopper:
  first_name: Deleted
  last_name: Shopper
  email: deleted@example.com
  company: vista
  store: los_angeles
  is_deleted: true

no_contact_shopper:
  first_name: Ghost
  last_name: Person
  company: vista
  store: los_angeles
  is_do_not_contact: true
  sms_contact: false
  email_contact: false
  whatsapp_contact: false
```

Separating exported data from synthetic edge cases keeps the fixture file organized. The top section is "the world as it normally looks." The bottom section is "the weird stuff we need to test." A comment separates them.

## Let Rails resolve the foreign keys

One of the reasons old fixture setups were fragile was hardcoded IDs. Change an ID in one file, and a dozen other files break. Rails solved this years ago with association labels, but I still see codebases that don't use them.

Every fixture in our suite references associations by label, not by ID:

```yaml
jen_wilson:
  first_name: Jennifer
  last_name: Wilson
  company: vista
  store: los_angeles
  role: manager
```

`company: vista` resolves to whatever ID Rails assigns to the `vista` fixture in `companies.yml`. No hardcoded integers. No cross-file dependencies on specific IDs. If I rename a fixture, I rename the label everywhere and it all still works.

The one exception is polymorphic associations. Rails can't resolve labels for polymorphic foreign keys because it doesn't know which table to look in. For those, we use ERB:

```yaml
jen_chat_participant:
  chat: jen_intro_chat
  participant_type: SalesAssociate
  participant_id: <%= ActiveRecord::FixtureSet.identify(:jen_wilson) %>
```

`FixtureSet.identify` is deterministic: given a label, it always returns the same integer. So while this is technically a hardcoded ID, it's derived from the label and stays in sync automatically.

## Know when not to use fixtures

This is the part that most "fixtures vs factories" debates miss. It's not one or the other. We use both, and the boundary is clear.

**Fixtures** are for the shared world. The baseline data that most tests read from but don't modify. Companies, stores, users, products, reference data. Loaded once per parallel worker, transactionally rolled back between tests. Fast, stable, predictable.

**Inline factory helpers** are for test-specific scenarios. Data that a test creates, mutates, or destroys. Edge cases that would bloat the fixture files. Records where you need precise control over every attribute.

We built an `InlineFactoryHelpers` module with about fifty `create_*` methods. It's FactoryBot without FactoryBot: plain Ruby methods that create records with sensible defaults and keyword arguments for overrides. A shared sequence starting at 10,000 avoids ID collisions with fixture data.

```ruby
def create_shopper(company: vista_company, store: la_store, **attrs)
  seq = next_sequence
  Shopper.create!(
    first_name: attrs[:first_name] || "Shopper",
    last_name: attrs[:last_name] || "#{seq}",
    email: attrs[:email] || "shopper-#{seq}@example.com",
    company: company,
    store: store,
    **attrs.except(:first_name, :last_name, :email)
  )
end
```

Notice that the defaults reference fixture helpers (`vista_company`, `la_store`). Inline-created records live in the same world as fixtures. They share the same company, the same stores. There's no parallel universe of factory data that doesn't match anything.

Here are the cases where we reach for inline creation instead of fixtures:

**Tests that destroy records.** If your test calls `shopper.destroy!`, you can't use a fixture because it'll be gone for the next test (or, with transactional tests, it'll roll back but the association caches might be stale). Create a disposable record instead.

**Uniqueness constraint testing.** When you need to verify that creating a duplicate raises an error, you create the record inside the test so you control the exact attributes.

**Parameterized edge cases.** One test that needs nineteen shoppers with specific combinations of contact preferences. That's not a fixture scenario; that's a loop with `create_shopper`.

**Elasticsearch tests that need isolation.** Some search tests index records and assert on search results. They use the ES Test clean-room company and create all their data inline so the index contains exactly what they expect.

About half our test files still use `create_*` methods. That's fine. The goal was never to eliminate all record creation, just to stop building the entire world from scratch in every test.

## The practical difference

With FactoryBot, our test setup blocks looked like this:

```ruby
let(:company) { create(:company) }
let(:store) { create(:store, company: company) }
let(:sa) { create(:sales_associate, company: company, store: store) }
let(:shopper) { create(:shopper, company: company, store: store) }
let(:appointment) { create(:appointment, sales_associate: sa, shopper: shopper) }
```

Five lines of setup to get an appointment. Each `create` hits the database. Each one builds a complete object graph that might not match what's in production. And this was in almost every test file.

With fixtures, the same test setup is:

```ruby
setup do
  @sa = manager_sa
  @shopper = male_shopper
  @appointment = appointments(:jen_russell_meeting)
end
```

Three lines. No database writes. The data is already there, already consistent, already real. The test starts by reading the world, not by building one.

Multiply that by hundreds of test files, and you start to understand where the speed comes from. It's not just parallel testing. It's not hitting the database hundreds of times during setup.

## What I'd do differently

If I did this again, I'd write the export script earlier. I spent the first few phases with minimal fixtures (just the scaffolded `:one`/`:two` defaults) and converted to real fixtures at Phase 3.5. Those early phases would have been cleaner if the fixtures existed from the start.

I'd also add more edge-case fixtures upfront. Most of the synthetic records were added reactively, when a test needed them. Having a "fixture wishlist" from the beginning would have saved some back-and-forth.

And I'd start with the three-company structure immediately. The single-tenant setup worked for the first few phases, but as soon as I hit model and service tests, the lack of cross-tenant data became a problem.

The core approach, though, I wouldn't change. Export real data, name everything meaningfully, let Rails resolve foreign keys, and use inline creation only when fixtures genuinely don't fit. Fixtures aren't the problem. Careless fixture design is.

Next up: parallel test isolation with Elasticsearch, and why running search tests across twelve workers is harder than it sounds.
