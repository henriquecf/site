A customer wanted to connect their Stripe account. They clicked the button, saw nothing happen, clicked again, and eventually emailed support.

Solid Errors had been quietly collecting the fallout: a string of `RecordNotUnique` exceptions on `StripeConnector`, one per extra click. The database was rejecting duplicate rows because `stripe_connectors` has a uniqueness constraint on `organization_id`. The first click, the one that should have worked, was nowhere in the error log. It had completed successfully. No error, no 500, no Sentry ping. Just a button that looked like it did nothing.

The redirect to `connect.stripe.com` was never happening.

## Tracing it backward

I opened Claude Code and started by staring at the controller.

```ruby
def create
  account = Stripe::Account.create(type: "standard")
  connector = current_organization.create_stripe_connector!(
    account_id: account.id
  )

  account_link = Stripe::AccountLink.create(
    account: connector.account_id,
    return_url: return_url,
    refresh_url: refresh_url,
    type: "account_onboarding"
  )

  redirect_to account_link.url, allow_other_host: true
end
```

It looked fine. `allow_other_host: true` was already in place. `Stripe::AccountLink.create` was generating a valid URL, and production logs confirmed that much. `redirect_to` was being called. Rails was sending back a 302 with the right `Location` header.

The redirect response was leaving the server. It just wasn't arriving at the browser.

Claude suggested checking whether the button was Turbo-driven. I went to look.

```erb
<%= button_to "Conectar Stripe", admin_stripe_connect_path,
      method: :post, class: "btn btn-primary btn-sm" %>
```

That's when it clicked. `button_to` generates a form. Any form in a Turbo-enabled app gets submitted via `fetch` instead of a real browser navigation. Turbo's `fetch` follows redirects internally. When the redirect points to your own domain, Turbo loads the response into the page. When it points to a different origin, Turbo can't use the response. The browser returns an opaque cross-origin response, and Turbo stops. Quietly.

No error in the console. No warning. The user sees a button that looked like it did nothing.

## The silent failure is the real problem

If Turbo logged a warning, I would have caught this in development. If it threw an error the user could see, support would have flagged it the first day. If anything had been raised at all, Solid Errors would have picked it up.

Instead, the failure mode is "the button doesn't work." Users click again. Some of them double-click out of habit. Each click creates a new `Stripe::Account` on Stripe's side (a real, permanent account) and attempts to insert a new `StripeConnector` row locally. The first one succeeds. The rest fail on the uniqueness constraint. The errors in Solid Errors are a symptom of users frustratedly mashing the button, not the original bug.

The original bug left no trace at all.

## Three things had to line up

Once I understood the failure mode, I could see that removing any one of three things would have prevented the bug. Not the fix. The bug.

**Turbo's default behavior.** In Rails 7+, `form_with` and `button_to` produce Turbo-driven forms by default. That's the right default for most forms. It's the wrong default for every form whose redirect crosses origins, and the framework has no way to know which is which. There's no warning, no lint rule, no dev-mode message saying "this redirect crossed origins and got dropped." The default is convenient everywhere it works and silent everywhere it doesn't.

**Claude didn't flag it.** I wrote the Stripe Connect flow with Claude Code and got working code on the first try. It really was working code, for a definition of "working" that includes posting to the right endpoint, generating the right Stripe URL, and receiving a valid redirect from Rails. What it didn't include was actually landing the user on Stripe. The model has enough Rails and Hotwire training data to use Turbo correctly on the happy path. It doesn't have enough to preemptively think "this form redirects off-origin, I should disable Turbo." That's a senior-level piece of lore the training data doesn't highlight, because blog posts mostly cover the happy path.

**My create wasn't idempotent.** Even if Turbo had followed the redirect correctly, a user who clicked fast enough could have fired two requests before the first finished. The controller called `Stripe::Account.create` unconditionally and then `create_stripe_connector!` unconditionally. Two clicks, two real Stripe accounts, two attempted rows. That one was on me. A button that creates an external resource should short-circuit if the resource already exists.

The fix was three changes:

```ruby
def create
  connector = current_organization.stripe_connector

  unless connector
    account = Stripe::Account.create(type: "standard")
    connector = current_organization.create_stripe_connector!(
      account_id: account.id
    )
  end

  # ...generate account link and redirect
end
```

Plus `data: { turbo: false }` on the button. Plus a fresh appreciation for how invisible this category of bug can be.

## The audit

Once I knew what to look for, I opened every view in the app and checked. Any form whose controller redirects cross-origin. Any link that navigates cross-origin. Not just Stripe.

The app is multi-tenant. Organizations live on subdomains (`centro-1.espirita.club`, `estudantesdoevangelho.espirita.club`) while the platform lives on the base domain. Every login crosses origins: a user logs in on the platform, and the server redirects them to their subdomain admin. Every logout crosses the other way. Every org switch. Every "view all organizations" link in the admin nav. Public checkout forms redirect to Stripe. The customer portal link redirects to Stripe. The donation flow redirects to Stripe.

All of them were Turbo-enabled. All of them had been "working" in the same way Stripe Connect was "working": the redirect reached Turbo, Turbo couldn't follow it, the user saw nothing. Some paths happened to still land the user somewhere useful because a full-page reload was triggered elsewhere in the flow. Others hung.

By the end of the audit, `data-turbo: false` was annotating close to a dozen views: login forms, logout buttons, org picker links, admin layout nav, Stripe Connect buttons, Stripe Checkout subscribe buttons, customer portal links, donation forms, and the public checkout form.

Every one of those is a place where the app is telling the browser: this navigation is leaving our origin, please handle it the old-fashioned way. Turbo doesn't get to help here.

## Tests I wrote next

The scariest part of this bug is that it's nearly invisible in development. I develop on `localhost` with subdomains like `estudantesdoevangelho.localhost`. Those are technically cross-origin from Turbo's perspective, and they do exhibit the broken behavior. But in development, I'm rapidly switching pages, restarting the server, doing full reloads. I don't sit with any one silent redirect long enough to notice. In production, a user clicks once, sees nothing, clicks again, emails me.

So I wrote integration tests for every cross-domain redirect in the app. Platform login to subdomain admin. Subdomain logout to platform root. Admin login for non-members to the platform org picker. Email confirmation to subdomain. I also added E2E coverage for external Stripe redirects so that if someone (me, Claude, a future contributor) accidentally removes `data-turbo: false`, the test breaks before production does.

The tests don't directly assert on Turbo behavior. They assert on the redirect location the server returns. Combined with the annotations in the views, the combination is enough to catch regressions.

## What I keep thinking about

The thing that bothers me about this bug isn't that it happened. Every Rails and Hotwire app has to learn this lesson once. What bothers me is how invisible it was.

Rails teaches you to trust the framework. Turbo teaches you to trust that your forms submit, your redirects follow, and the user ends up where your controller told them to go. That's a good default. I like Hotwire. I'm not writing hand-rolled JavaScript for navigation again.

But the guarantee Turbo makes is implicit: your navigation will work as long as it stays on your origin. And origin is a property the controller decides at runtime, not a property of the form at render time. The framework can't check it when the view is rendered. It doesn't even know the form is about to redirect cross-origin, because that decision hasn't happened yet. The only entity who knows is the developer writing `redirect_to account_link.url`, and that developer has to have internalized "if this might leave my origin, the form that triggered it must not be Turbo-driven."

That's a lot of load to put on the developer, and the penalty for forgetting is a bug that doesn't show up in tests, doesn't show up in logs, doesn't show up in error tracking, and only shows up when a user writes in.

I've added the annotations. I've written the tests. I know the pattern now. But I'm going to forget it once a year, and the LLM I write with is going to keep producing Turbo-driven forms pointed at off-origin redirects, and the bug will still be invisible when it happens. The only structural fix I've found is: every cross-domain redirect in your app needs a test, and those tests need to run in CI. Everything else is vibes.
