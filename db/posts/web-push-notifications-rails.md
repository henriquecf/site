I wanted visitors to get reminders before activities and events start. Not email reminders that get buried, not SMS that costs money per message. Browser push notifications: free, instant, and they work even when the tab is closed.

The platform is a multi-tenant Rails app where community organizations manage events and recurring activities. A visitor lands on an activity page, taps a bell icon, picks how far in advance they want to be reminded, and that's it. Fifteen minutes before their yoga class starts, their phone buzzes. No account required, no email address collected.

Getting the basic flow working took a day. Getting it working *correctly* across browsers, on iOS, with recurring schedules and timezone-aware delivery windows took considerably longer. This is the full implementation, including every gotcha I hit along the way.

## How Web Push actually works

Web Push is a W3C standard, not a proprietary API. The flow involves three parties: your server, the browser's push service (operated by Google, Mozilla, or Apple), and the service worker running in the user's browser.

The handshake goes like this:

1. Your server generates a VAPID key pair (Voluntary Application Server Identification). This is a one-time setup. The public key goes to the browser, the private key stays on your server.
2. The user grants notification permission. The browser contacts its push service and returns a subscription object containing an endpoint URL and encryption keys.
3. Your server stores that subscription. When it's time to send a notification, it encrypts the payload using the subscription's keys, signs it with the VAPID private key, and POSTs it to the endpoint URL.
4. The push service delivers it to the browser, which wakes up the service worker, which shows the notification.

No WebSocket connection, no polling. The push service handles delivery, queuing, and retries. Your server just fires HTTP requests.

## The data model

Two tables handle the subscription state. A `PushSubscriber` represents a device subscribed to a specific organization:

```ruby
# push_subscriber.rb
class PushSubscriber < ApplicationRecord
  include BelongsToOrganization

  has_many :push_item_subscriptions, dependent: :destroy
  has_many :subscribed_activities, through: :push_item_subscriptions,
           source: :subscribable, source_type: "Activity"
  has_many :subscribed_events, through: :push_item_subscriptions,
           source: :subscribable, source_type: "Event"

  validates :endpoint, presence: true,
            uniqueness: { scope: :organization_id }
end
```

The `endpoint` is the URL the push service gave us. It's unique per device per organization. The subscriber also stores `p256dh_key` and `auth_key` (encryption keys from the browser), plus optional `first_name` and `timezone` fields.

A `PushItemSubscription` tracks what the subscriber wants reminders for:

```ruby
# push_item_subscription.rb
class PushItemSubscription < ApplicationRecord
  belongs_to :push_subscriber
  belongs_to :subscribable, polymorphic: true

  enum :reminder_timing, {
    thirty_minutes: 0,
    one_hour: 1,
    two_hours: 2,
    morning_of: 3,
    day_before: 4
  }, default: :one_hour
end
```

I initially put `reminder_timing` on the subscriber level, one timing for everything. That lasted about a day before I realized people want a one-hour reminder for their weekly study group but a morning-of reminder for a weekend retreat. Moving it to the join table was a small migration and a much better model.

The polymorphic `subscribable` points to either an Activity or an Event, handled by a concern mixed into both:

```ruby
# push_subscribable.rb
module PushSubscribable
  extend ActiveSupport::Concern

  included do
    has_many :push_item_subscriptions, as: :subscribable, dependent: :destroy
    has_many :push_subscribers, through: :push_item_subscriptions
  end
end
```

## The service worker

The service worker is the piece that runs in the background and shows notifications even when the user isn't on your site. Mine is an ERB template served from a Rails controller so I can inject the asset paths:

```javascript
self.addEventListener("push", event => {
  const { title, body, icon, badge, data } = event.data.json()
  event.waitUntil(
    self.registration.showNotification(title, {
      body, icon, badge, data,
      actions: [
        { action: "open", title: "Ver" },
        { action: "manage", title: "Gerenciar notificações" }
      ]
    })
  )
})
```

The notification includes two actions: open the relevant page, or go to the manage page where the subscriber can change their preferences.

The click handler needs to do two things: close the notification and open the right URL. This sounds simple, and it is, until you try to be clever.

```javascript
self.addEventListener("notificationclick", event => {
  event.notification.close()
  const path = event.action === "manage"
    ? "/push_subscriptions/manage"
    : (event.notification.data?.path || "/")

  event.waitUntil(
    clients.matchAll({ type: "window" }).then(windowClients => {
      for (const client of windowClients) {
        if (client.url.includes(path)) {
          return client.focus()
        }
      }
      return clients.openWindow(path)
    })
  )
})
```

My first version of the manage action tried to call `self.registration.pushManager.getSubscription()` to append the endpoint as a query parameter. That's an async call. By the time it resolved, the browser had already consumed the user gesture, and `clients.openWindow()` failed silently. The fix was simple: let the manage page detect the subscription itself with client-side JavaScript after it loads. Don't do async work in notification click handlers if you need the user gesture.

## Client-side subscription

A Stimulus controller on the bell icon handles the subscription flow. The core of it:

```javascript
async toggle() {
  if (!("Notification" in window) || !("serviceWorker" in navigator)) {
    alert("Seu navegador não suporta notificações push.")
    return
  }

  if (this.isIosSafari()) {
    // Show install-to-home-screen instructions
    this.showIosModal()
    return
  }

  const data = this.getSubscriberData()
  if (!data) {
    await this.subscribe()
  } else if (this.isItemSubscribed(data)) {
    await this.unsubscribeItem(data.id)
  } else {
    this.showModal(data.id)
  }
}
```

The `subscribe()` method does the VAPID dance:

```javascript
async subscribe() {
  const permission = await Notification.requestPermission()
  if (permission !== "granted") return

  const reg = await navigator.serviceWorker.ready
  const response = await fetch("/push_subscriptions/vapid_public_key")
  const { vapid_public_key } = await response.json()

  const subscription = await reg.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: this.urlBase64ToUint8Array(vapid_public_key)
  })

  const keys = subscription.toJSON()
  const res = await fetch("/push_subscriptions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      endpoint: keys.endpoint,
      p256dh_key: keys.keys.p256dh,
      auth_key: keys.keys.auth,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone
    })
  })

  const { id, first_name } = await res.json()
  this.saveSubscriberData({ id, endpoint: keys.endpoint, firstName: first_name, items: [] })
  this.showModal(id)
}
```

The subscriber data lives in localStorage, keyed per organization. It's a cache of the server state: subscriber ID, endpoint, name, and which items they're subscribed to. The bell icon fills or outlines based on this local state, so it's instant even on slow connections.

## Server-side delivery

The `web-push` gem handles the encryption and HTTP calls. I wrapped it in a `PushNotifier` class:

```ruby
class PushNotifier
  def self.notify(push_subscriber, title:, body:, path: "/", icon: nil)
    payload = {
      title: title,
      body: body,
      icon: icon || icon_url_for(push_subscriber.organization),
      data: { path: path }
    }.to_json

    WebPush.payload_send(
      message: payload,
      endpoint: push_subscriber.endpoint,
      p256dh: push_subscriber.p256dh_key,
      auth: push_subscriber.auth_key,
      vapid: vapid_keys
    )
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
    push_subscriber.destroy
  rescue WebPush::Error => e
    SolidErrors.report(e)
  end
end
```

Two things worth noting. First, expired subscriptions: when a user clears their browser data or uninstalls the PWA, the push service returns a 410. The gem raises `ExpiredSubscription`, and I delete the subscriber. No stale records piling up. Second, VAPID keys come from Rails credentials (or ENV vars as fallback), generated once with `WebPush.generate_key`.

## Recurring reminders with Solid Queue

Two jobs run every 15 minutes via Solid Queue's `recurring.yml`:

```yaml
schedule_activity_reminders:
  class: ScheduleActivityRemindersJob
  every: 15.minutes

schedule_event_reminders:
  class: ScheduleEventRemindersJob
  every: 15.minutes
```

The event reminder job is straightforward: iterate subscriptions, check if the event's `starts_at` falls within the subscriber's reminder window, send the notification. The activity reminder job is more interesting because activities recur on schedules. A meditation group meets every Tuesday and Thursday at 7 PM, except on holidays, and it's paused during January.

A `CalendarExpander` service resolves all of this. It takes a date range and returns concrete occurrences, accounting for the recurring schedule, closed dates, and activity pauses:

```ruby
entries = CalendarExpander.new(org, Date.current, 1.day.from_now.to_date)
                          .entries_for(activity)
```

Each entry has a date, start time, location, and the activity reference. The reminder job iterates these entries and checks whether the occurrence falls within the subscriber's chosen reminder window.

Deduplication uses Solid Cache instead of the database. Each notification gets a cache key like `push_reminder:event:42:sub:7:2026-03-09`. If the key exists, the notification was already sent today. The cache entry expires after 24 hours. This handles the case where the job runs four times within an hour (every 15 minutes) and the event is still within the reminder window for all four runs.

```ruby
cache_key = "push_reminder:event:#{event.id}:sub:#{subscriber.id}:#{Date.current}"
return if Rails.cache.exist?(cache_key)

SendPushNotificationJob.perform_later(subscriber.id, title:, body:, path:)
Rails.cache.write(cache_key, true, expires_in: 24.hours)
```

The notification body adapts based on timing. A one-hour reminder says "Começa em 1h" (starts in 1 hour). A morning-of reminder says "Hoje" (today). A day-before reminder says "Amanhã" (tomorrow). If the subscriber has a first name, it opens with "Olá, Henrique!" instead of diving straight into the schedule.

## The iOS problem

Web Push on iOS only works when your site is installed as a Progressive Web App. Regular Safari on iPhone doesn't support the Push API at all. This isn't a bug or a missing polyfill. Apple requires the user to add the site to their home screen first.

Detecting this:

```javascript
isIosSafari() {
  const ua = navigator.userAgent
  const isIos = /iPad|iPhone|iPod/.test(ua) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  const isStandalone = window.navigator.standalone === true ||
    window.matchMedia("(display-mode: standalone)").matches
  return isIos && !isStandalone
}
```

The `MacIntel` with touch points check catches iPads that report as Macs. If it's iOS but not standalone, I show a modal with step-by-step instructions: tap the share button, select "Add to Home Screen." Once installed, the Push API becomes available and the normal flow kicks in.

I went back and forth on whether to just hide the bell icon on iOS Safari. Showing it and then telling people they need to install the app first feels clunky. But hiding it means iOS users never discover the feature. The install modal won, because at least it gives them a path forward.

## Other gotchas

**Turbo and service workers.** Turbo Drive intercepts navigation, which means the service worker's `fetch` event sees Turbo's requests, not full page loads. My service worker uses a network-first strategy for navigation requests with a fallback to a cached `/offline` page. This works with Turbo because Turbo's requests still have `mode: "navigate"` on the initial page load and hard navigations. For Turbo-driven navigations (which are `fetch` requests, not navigations), the service worker lets them pass through without caching interference.

**`userVisibleOnly` vs. typos.** The Push API subscription call requires `userVisibleOnly: true`. My first version had `userNotificationAllowed: true`, which is not a real option. The browser silently accepted it and the subscription worked, but it's technically non-compliant. Caught it in code review.

**CSRF and API endpoints.** The subscription endpoints receive JSON from JavaScript running on the public site. I skip CSRF verification on the controller because the requests come from `fetch()` calls, not form submissions. The alternative would be to extract the CSRF token from the meta tag and include it in headers, but since these endpoints don't modify any authenticated state (subscriptions are anonymous), skipping CSRF is the simpler choice.

**Stale bell state.** The bell icon state comes from localStorage, which can get out of sync with the server. If a user clears site data but the subscription still exists server-side, the bell shows as unsubscribed even though the push endpoint might still be active. The next time they subscribe, the controller does a find-or-initialize by endpoint, so it picks up the existing record. Good enough.

## The manage page

Subscribers need a way to change their preferences or unsubscribe without digging through browser settings. The manage page at `/push_subscriptions/manage` lists all their subscribed items with timing controls and unsubscribe buttons. It also lets them update their name and timezone.

Finding the right subscriber is the interesting part. The manage page needs to know which `PushSubscriber` record belongs to this device. The URL can include an `endpoint` parameter (linked from notification toasts), but if someone navigates there directly, a script on the page calls `registration.pushManager.getSubscription()` and uses the endpoint to look up their record.

```javascript
const reg = await navigator.serviceWorker.ready
const sub = await reg.pushManager.getSubscription()
if (sub) {
  window.location.replace(`/push_subscriptions/manage?endpoint=${encodeURIComponent(sub.endpoint)}`)
}
```

When the subscriber updates their name on the manage page, it also syncs to localStorage so the bell icon's modal shows the updated name in future sessions.

## What I'd do differently

The reminder jobs evaluate time windows using the server's timezone. If the server is in UTC and a subscriber is in São Paulo (UTC-3), a "morning_of" reminder configured to fire between 7-8 AM will fire at 7 AM UTC, which is 4 AM in São Paulo. The subscriber's timezone is stored but not currently used for window evaluation. This hasn't been a problem yet because all the organizations on the platform are in Brazil and the server is configured for that timezone, but it would break for a globally distributed user base.

I'd also consider moving deduplication from cache to database. Solid Cache works fine, but cache entries can disappear if the cache store is cleared. A `push_notification_logs` table with a unique index would be more durable, though also more writes. For the current scale, cache deduplication hasn't caused any issues.

The whole system runs on the free tier of everything. Solid Queue for jobs, Solid Cache for dedup, the `web-push` gem for delivery. No external notification service, no per-message costs. For a community platform where the organizations don't generate revenue, that matters a lot.
