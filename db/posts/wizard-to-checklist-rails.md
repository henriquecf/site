I had a five-step onboarding wizard. Each step was its own controller, its own view, its own route. The whole flow lived in a dedicated layout. You signed up, and before you could see your dashboard, you had to walk through every step: confirm your email, fill out your profile, add your first listing, upload a logo, write a description. All five, in order, no skipping.

It worked at first. When the product launched, users needed guidance, and a wizard gave them a clear path. But over time, it became a wall. Users would sign up, get stuck on step three, and leave. Some would email support asking how to skip the logo upload. Others would abandon the flow entirely. The wizard went from helpful to hostile.

I ripped it out and replaced it with a setup guide: a collapsible card on the dashboard showing what you need to do, without blocking you from anything. It took a day. Most of that was deleting code.

## What the good ones do

Open Stripe for the first time. You land on your dashboard immediately. There's a setup guide showing your next steps, but you can click around, explore the API docs, even start building an integration before you've finished onboarding. Linear does the same thing. So does Notion. The pattern is consistent: land users on the real product, show them what to complete, and distinguish between what's required and what's nice to have.

The required-vs-optional distinction matters. Stripe won't let you process payments until you've verified your identity and connected a bank account, but it won't nag you about setting a custom icon. That's the right UX tradeoff. Block on the things that actually gate functionality, encourage everything else.

A wizard makes sense for a flow that must happen in sequence (payment checkout, legal agreements). Onboarding rarely fits that model. Users don't need to upload a logo before they can add their first listing. They just need to know that uploading a logo is something they can do.

## The SetupGuide PORO

I wanted something with no database footprint. Progress shouldn't be stored, it should be computed from the state that already exists. If the user has confirmed their email, that step is complete. If the organization has listings, that step is complete. No need for a `setup_progress` table or a `completed_steps` JSON column.

Here's the full implementation:

```ruby
class SetupGuide
  Step = Data.define(:key, :title, :description, :completed, :required, :path)

  attr_reader :steps

  def initialize(organization:, user:)
    @organization = organization
    @user = user
    @steps = build_steps
  end

  def completed_count
    @steps.count(&:completed)
  end

  def total_count
    @steps.size
  end

  def progress_percentage
    return 0 if total_count.zero?
    (completed_count * 100.0 / total_count).round
  end

  def all_required_complete?
    @steps.select(&:required).all?(&:completed)
  end

  def visible?
    !@organization.published?
  end

  def dismissed?
    @organization.setup_guide_dismissed_at.present?
  end

  private

  def build_steps
    [
      Step.new(
        key: :confirm_email,
        title: "Confirm your email",
        description: "Check your inbox and click the confirmation link.",
        completed: @user.email_confirmed?,
        required: true,
        path: nil
      ),
      Step.new(
        key: :complete_profile,
        title: "Complete your profile",
        description: "Add contact info, social links, or a cover image.",
        completed: profile_enriched?,
        required: true,
        path: :edit_admin_settings_path
      ),
      Step.new(
        key: :add_listings,
        title: "Add listings",
        description: "Create the listings your organization offers.",
        completed: @organization.listings.any?,
        required: true,
        path: :admin_listings_path
      ),
      Step.new(
        key: :add_description,
        title: "Write a description",
        description: "Tell visitors what your organization is about.",
        completed: @organization.description.present?,
        required: false,
        path: :edit_admin_settings_path
      ),
      Step.new(
        key: :upload_logo,
        title: "Upload your logo",
        description: "Add a logo to personalize your page.",
        completed: @organization.logo.attached?,
        required: false,
        path: :edit_admin_settings_path
      ),
      Step.new(
        key: :review_documents,
        title: "Review documents",
        description: "Upload bylaws, policies, or other files.",
        completed: @organization.documents_visited_at.present?,
        required: false,
        path: :admin_settings_path
      )
    ]
  end

  def profile_enriched?
    @organization.phone.present? ||
      @organization.whatsapp.present? ||
      @organization.tagline.present? ||
      @organization.instagram.present? ||
      @organization.facebook.present? ||
      @organization.mission.present? ||
      @organization.icon.attached? ||
      @organization.cover_image.attached?
  end
end
```

A few things worth noting.

`Data.define` creates an immutable value object. Each `Step` has a fixed set of fields, and once you create one, you can't change it. This is exactly what you want for something that represents a snapshot of current state. The step is either complete or it isn't. There's no updating it later.

The class is a plain Ruby object. No `ActiveRecord`, no `ApplicationRecord`, no database table. It takes an organization and a user in its constructor, builds the steps, and that's it. You instantiate it in the controller, pass it to the view, and it gets garbage collected at the end of the request. There's nothing to persist because there's nothing new to store.

## Step completion logic

Every step computes its completion from existing model state. `@user.email_confirmed?` is a method that already existed for email verification. `@organization.listings.any?` is a standard ActiveRecord check. `@organization.logo.attached?` uses Active Storage. None of these required new code.

The interesting one is `profile_enriched?`. This checks whether the user has filled in *any* field beyond what registration collects. Not all fields, not specific fields, just any of them. Phone number? Done. Instagram handle? Done. Cover image? Done. It's a lenient check on purpose.

I could have made it stricter. "Complete your profile" could mean "fill in these five specific fields." But that would recreate the wizard problem at a smaller scale: users getting blocked because they don't have a Facebook page to link. The lenient check means a single additional piece of information counts as engagement. You filled in your phone number? Great, you've engaged with your profile, this step is done.

```ruby
def profile_enriched?
  @organization.phone.present? ||
    @organization.whatsapp.present? ||
    @organization.tagline.present? ||
    @organization.instagram.present? ||
    @organization.facebook.present? ||
    @organization.mission.present? ||
    @organization.icon.attached? ||
    @organization.cover_image.attached?
end
```

The OR chain is ugly, sure. But it's explicit, easy to extend (just add another line), and dead simple to test. I'll take readable over elegant when the logic is this straightforward.

## Required vs optional

The steps split into two groups. Three required, three optional. The required ones gate a real action: publishing the organization's page to the public.

```ruby
def all_required_complete?
  @steps.select(&:required).all?(&:completed)
end
```

In the view, the publish button is disabled until this returns `true`. The required steps are confirm email, complete profile, and add listings. These are the minimum for a page that isn't empty. Everything else (description, logo, documents) makes the page better but doesn't make it broken.

Optional steps show up in the same list with the same checkmarks. They look the same, feel the same, but they don't block anything. Users can publish with three completed steps and three unchecked optional ones. They'll see the optional steps on their dashboard and probably complete them eventually. Or not. That's fine too.

This split is where the wizard analogy breaks down completely. A wizard treats every step as required by design. You can't skip step four. You can't go back to step two without going through three. The mental model is a sequence. The setup guide's mental model is a checklist, and some items on the checklist are bold.

## Dashboard integration

The controller creates the guide and passes it to the view:

```ruby
class Admin::DashboardController < BaseController
  def show
    @setup_guide = SetupGuide.new(
      organization: current_organization,
      user: Current.user
    )
  end
end
```

The view conditionally renders it:

```erb
<% if @setup_guide.visible? && !@setup_guide.dismissed? %>
  <%= render "admin/dashboard/setup_guide", guide: @setup_guide %>
<% end %>
```

Two conditions control visibility. `visible?` returns `true` when the organization hasn't published yet, because once you're live, you don't need the guide anymore. `dismissed?` checks a timestamp column on the organization:

```ruby
def dismissed?
  @organization.setup_guide_dismissed_at.present?
end
```

The dismiss action sets a timestamp, not a boolean. This is a small thing that has practical benefits. If you later decide to un-dismiss guides for organizations that haven't completed a new required step, you just clear the timestamp. You can also query "when did they dismiss it?" for analytics. A boolean would only tell you the current state.

```ruby
def dismiss_setup_guide
  current_organization.update!(setup_guide_dismissed_at: Time.current)
  redirect_to admin_root_path
end
```

The partial itself renders a progress bar and a list of steps. Each step links to its `path` if one exists (some steps, like email confirmation, don't have a page to link to). Completed steps get a checkmark. The whole thing collapses into a single line if you want to minimize it.

## Cleaning up

The best part of this refactor was the deletion. The old wizard had five controllers (one per step), five views, a shared layout, route definitions with step ordering logic, and a before_action that redirected users back to the wizard if they tried to access the dashboard before completing it.

All of that went away. The routes file got a simple redirect:

```ruby
# Redirect old onboarding URLs
get "onboarding", to: redirect("/admin")
get "onboarding/*path", to: redirect("/admin")
```

Anyone who bookmarked the old wizard URL, or has it in an email, lands on the dashboard instead. The setup guide is right there waiting for them.

The before_action that enforced the wizard was the most important thing to remove. In the old system, hitting `/admin` when you hadn't completed onboarding would redirect you to `/onboarding/step/1`. This was the core of the blocking behavior. Deleting that one line changed the product from "you must complete these steps" to "you should complete these steps." Same steps, completely different relationship with the user.

## When this pattern works

This isn't universal. Multi-step payment flows should still be wizards. Legal compliance flows where you need signatures in a specific order should still be wizards. Anything where the sequence matters and partial completion is meaningless should be a wizard.

But onboarding in a SaaS product? It's almost always a checklist. Users need to do several independent things, and the order rarely matters. "Confirm email" and "add your first listing" are not dependent on each other. The wizard was imposing a sequence where none existed.

The PORO approach keeps everything in one file, one class, with completion computed from state you're already tracking. You can extract it to a concern, parameterize the steps, or use it as a template for a different guide somewhere else in the app. There's nothing framework-specific about the pattern beyond the ActiveRecord calls in the completion checks, and even those could be swapped for any data source.

If your onboarding has steps that don't depend on each other, and you're forcing users through them one by one, try a checklist. You probably already have everything you need in your models to compute progress. You don't need a new table. You just need a PORO and a partial.
