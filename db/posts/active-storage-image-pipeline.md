A user told me the images on the site felt slow. "Every time I open a page, the images seem to reload." I opened DevTools, navigated to a page with event cards, and watched the network tab. Every image triggered a 302 redirect to a signed blob URL. The response headers said `Cache-Control: max-age=300`. Five minutes. The browser was faithfully re-fetching every image every five minutes, even though they hadn't changed in weeks.

Then I looked at the file sizes. The event card thumbnails were the original uploads, untouched. One of them was a 3.8MB JPEG straight from someone's phone. Rendered at 400×300 pixels in the card grid. The browser was downloading a full-resolution photo to display it smaller than a playing card.

Active Storage ships with sensible defaults for getting started. Upload a file, attach it to a model, render it in a view. It works. But the defaults optimize for "it works," not "it performs." There are three layers where things go wrong, and fixing all of them took a single afternoon.

## The three problems

When you use `has_one_attached` and render images with `url_for(model.image)`, Active Storage does the following by default:

1. **Serves the original file.** Whatever the user uploaded, that's what gets sent. A 4MB JPEG from a phone camera? That's the image in your event card. No resizing, no format conversion.

2. **Uses redirect mode.** The default `resolve_model_to_route` is `:rails_storage_redirect`, which returns a 302 redirect to a signed blob URL. That signed URL has a 5-minute expiry by default. Browsers cache the redirect itself, but once the signed URL expires, they fetch a new one.

3. **No upload validation.** Active Storage doesn't validate content type or file size at the model level. Someone can upload a 30MB TIFF as their profile icon, and Rails will happily store and serve it.

Each problem has a straightforward fix.

## Layer 1: WebP variants with a helper

The first fix is to stop serving original uploads. Instead of rendering the raw attachment, every image goes through a variant that resizes and converts to WebP.

I created an `ImageVariantsHelper` that centralizes all variant definitions:

```ruby
module ImageVariantsHelper
  WEBP_OPTIONS = { format: :webp, saver: { quality: 80 } }.freeze

  def cover_image_variant(attachment)
    attachment.variant(resize_to_limit: [1920, 1080], **WEBP_OPTIONS)
  end

  def logo_navbar_variant(attachment)
    attachment.variant(resize_to_fill: [36, 36], **WEBP_OPTIONS)
  end

  def activity_card_variant(attachment)
    attachment.variant(resize_to_fill: [400, 300], **WEBP_OPTIONS)
  end

  def activity_detail_variant(attachment)
    attachment.variant(resize_to_limit: [900, 500], **WEBP_OPTIONS)
  end

  def event_card_variant(attachment)
    attachment.variant(resize_to_fill: [320, 400], **WEBP_OPTIONS)
  end

  def admin_preview_variant(attachment)
    attachment.variant(resize_to_limit: [200, 200], **WEBP_OPTIONS)
  end

  def meta_image_variant(attachment)
    attachment.variant(resize_to_limit: [1200, 630], **WEBP_OPTIONS)
  end

  def favicon_variant(attachment)
    attachment.variant(resize_to_fill: [64, 64], format: :png)
  end
end
```

A couple of things to note about the variant options.

`resize_to_limit` keeps the original aspect ratio and constrains the image to fit within a maximum box. Use this for detail views and cover images where cropping would lose important content. `resize_to_fill` crops to exact dimensions, which is what you want for card grids and thumbnails where consistent sizing matters more than showing every pixel.

Why WebP over AVIF? AVIF compresses better, but encoding is significantly slower. For on-the-fly variant generation, that matters. WebP at quality 80 gives you roughly 70-80% size reduction over JPEG with encoding times in the tens of milliseconds. Good enough, and fast enough. The exception is favicons, which stay as PNG because some browsers and tools still don't handle WebP favicons well.

In views, instead of:

```erb
<%= image_tag url_for(activity.image) %>
```

It becomes:

```erb
<%= image_tag activity_card_variant(activity.image) %>
```

A 4MB phone JPEG turns into a 30KB WebP card thumbnail. The variant is generated on first request and cached by Active Storage in the `active_storage_variant_records` table. Subsequent requests serve the cached variant.

The helper approach keeps variant definitions in one place. When a designer says "can we make the event cards wider?" you change one method, and every event card across the app picks it up. No hunting through templates.

## Layer 2: proxy mode for real caching

The bigger performance issue was the caching behavior. In redirect mode, Active Storage returns a 302 to a signed URL:

```
GET /rails/active_storage/blobs/redirect/eyJfcm...
→ 302 → /rails/active_storage/disk/eyJfcm.../photo.jpg
  Cache-Control: max-age=300 (5 minutes)
```

After 5 minutes, the browser considers the URL stale and re-fetches. For images that change maybe once a month, that's a lot of unnecessary requests.

The fix is one line in `config/environments/production.rb`:

```ruby
config.active_storage.resolve_model_to_route = :rails_storage_proxy
```

Proxy mode changes the behavior completely. Instead of redirecting, Rails streams the file directly through the app. And it sets `Cache-Control: public, max-age=31536000` (1 year). The browser caches the response and doesn't ask again.

"But won't that bottleneck Puma?" It would, if every image request hit the Ruby process. In my setup, [Thruster](https://github.com/basecamp/thruster) sits in front of Puma as an HTTP proxy (it ships with Rails 8's default Dockerfile). Thruster caches any response with a `Cache-Control: public` header in memory. The first request for an image goes through Puma. Every subsequent request is served directly from Thruster's cache without touching Ruby.

The flow becomes:

```
Browser → Thruster (memory cache) → Puma (only on cache miss)
                                      ↓
                                  Active Storage (disk)
```

One thing to note: if you ever move images to S3 or a CDN, you'd want to switch back to redirect mode so the browser fetches directly from the CDN instead of routing through your app. Proxy mode is ideal when you're serving from local disk and have an HTTP cache layer in front.

For development, you probably don't want year-long caching. I use a shorter TTL:

```ruby
# config/environments/development.rb
config.active_storage.resolve_model_to_route = :rails_storage_proxy
config.public_file_server.headers = {
  "cache-control" => "public, max-age=#{2.days.to_i}"
}
```

Two days is long enough to avoid constant re-fetching during development but short enough that you'll see changes when you update an image.

I also set cache headers for static assets in production:

```ruby
config.public_file_server.headers = {
  "cache-control" => "public, max-age=#{1.year.to_i}"
}
```

## Layer 3: upload validation

Active Storage doesn't validate what gets uploaded. You can attach any file type, any size, and Rails will store it. For images, this means someone could upload a BMP, a TIFF, or a 50MB raw file, and your variant processor would have to deal with it.

Rails 8.1 still doesn't ship with built-in Active Storage validators. There are gems for this ([active_storage_validations](https://github.com/igorkasyanchuk/active_storage_validations) is the most popular), but the validation I needed was straightforward enough to build as a concern:

```ruby
module ValidatesImageAttachment
  extend ActiveSupport::Concern

  ALLOWED_IMAGE_CONTENT_TYPES = %w[
    image/jpeg image/png image/gif image/webp
  ].freeze

  class_methods do
    def validates_image_attachment(field, max_size:)
      validate do |record|
        attachment = record.public_send(field)
        next unless attachment.attached?

        blob = attachment.blob

        unless ALLOWED_IMAGE_CONTENT_TYPES.include?(blob.content_type)
          record.errors.add(field, :image_content_type_invalid)
        end

        if blob.byte_size > max_size
          max_label = ActiveSupport::NumberHelper
            .number_to_human_size(max_size, locale: :en)
          record.errors.add(field, :image_too_large, max_size: max_label)
        end
      end
    end
  end
end
```

Then in your models:

```ruby
class Activity < ApplicationRecord
  include ValidatesImageAttachment

  has_one_attached :image
  validates_image_attachment :image, max_size: 5.megabytes
end

class Organization < ApplicationRecord
  include ValidatesImageAttachment

  has_one_attached :icon
  has_one_attached :logo
  has_one_attached :cover_image

  validates_image_attachment :icon, max_size: 2.megabytes
  validates_image_attachment :logo, max_size: 2.megabytes
  validates_image_attachment :cover_image, max_size: 10.megabytes
end
```

The `validates_image_attachment` macro reads like any other Rails validation. It checks content type against a whitelist and enforces a size limit, with the max size formatted nicely in the error message ("is too large, maximum is 5 MB").

The concern skips validation if nothing is attached (`next unless attachment.attached?`), so the field stays optional. If you need a required image, add a separate `validates :image, presence: true`.

For the error messages, I added translations in the locale file:

```yaml
# config/locales/en.yml
en:
  errors:
    messages:
      image_content_type_invalid: "must be a JPEG, PNG, GIF, or WebP image"
      image_too_large: "is too large (maximum is %{max_size})"
```

The `number_to_human_size` call formats the byte limit into something readable, so users see "is too large (maximum is 5 MB)" instead of "is too large (maximum is 5242880)".

## What about preprocessing?

Active Storage supports `variant(:thumb)` declarations with `preprocessed` to generate variants ahead of time instead of on first request:

```ruby
has_one_attached :image do |attachable|
  attachable.variant :thumb, resize_to_fill: [400, 300], format: :webp
end
```

I considered this but went with the helper approach instead. Preprocessing runs as a background job when the file is uploaded. If you have several variant sizes per image (card, detail, admin preview, OG meta), that's multiple background jobs per upload. With the helper, variants are generated lazily on first request and then cached. For a site that doesn't have thousands of concurrent users hitting a new image simultaneously, lazy generation is simpler and works fine.

The tradeoff is that the very first visitor to see a new image pays the cost of variant generation. In practice, that's barely noticeable: vips processes a typical photo variant in under 100ms. And once generated, the variant is stored alongside the original blob, so it's never generated again.

If you do have high-traffic pages where a new image gets hit by many users simultaneously, preprocessing makes more sense. For admin-uploaded content on a community platform, lazy generation was the simpler choice.

## The impact

After deploying these three changes, I opened DevTools again and ran through the same pages. The network tab told a different story. Image responses came back as WebP with `Cache-Control: public, max-age=31536000`. The event card grid that used to transfer several megabytes of original JPEGs was now a handful of small WebP files. Navigating back and forth between pages produced zero image re-fetches. The `(disk cache)` label in Chrome's network tab is exactly what you want to see.

The changes touched the helper, the concern, one config line for proxy mode, and then updating templates to call variant helpers instead of raw `url_for`. The models gained `validates_image_attachment` calls. None of it required changing how images are uploaded or stored, only how they're served and validated.

## Quick reference

If you want to apply this to your own Rails app, here's the checklist:

**1. Switch to proxy mode** (one line):

```ruby
# config/environments/production.rb
config.active_storage.resolve_model_to_route = :rails_storage_proxy
```

**2. Create variant helpers** so you never serve originals:

```ruby
# app/helpers/image_variants_helper.rb
def card_variant(attachment)
  attachment.variant(resize_to_fill: [400, 300], format: :webp, saver: { quality: 80 })
end
```

**3. Add upload validation** to prevent oversized or wrong-format files:

```ruby
# app/models/concerns/validates_image_attachment.rb
# (full code above)
```

**4. Update your views** to use variants:

```erb
<%# Before %>
<%= image_tag url_for(model.image) %>

<%# After %>
<%= image_tag card_variant(model.image) %>
```

If you're running Thruster (default in Rails 8), proxy mode images get cached in memory automatically. If you're behind nginx or another reverse proxy, configure it to cache responses with `Cache-Control: public` headers, and you'll get the same benefit.

Active Storage does a lot right out of the box. But the performance defaults assume you'll configure them for production, and the framework doesn't push you to do it. These are small changes that make a real difference in how the site feels, especially on repeat visits.
