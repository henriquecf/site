Every page on a multi-tenant platform needs a social preview image. When someone shares a blog post, event, or org page on LinkedIn or Slack, the card that shows up is either a generic fallback or something that actually represents the content. I needed dynamic OG images for a community platform where each organization has its own theme colors, logo, and content. Hundreds of possible combinations, changing all the time.

The usual approach is to spin up a headless browser, render HTML to a screenshot, and serve the result. Puppeteer, Playwright, Satori, Vercel OG. They all work, and they all require Node.js. On a Rails 8 app running Propshaft and Import Maps, adding a Node.js runtime just for image generation felt wrong. There had to be a way to do this in Ruby.

Turns out, the tool was already installed. ruby-vips ships with Rails through Active Storage. It's what processes your image variants. And it can do a lot more than resize JPEGs.

## What ruby-vips can do

[libvips](https://www.libvips.org/) is an image processing library that's fast and memory-efficient. The Ruby binding, [ruby-vips](https://github.com/libvips/ruby-vips), exposes the full API. The parts that matter for OG image generation:

- **Pixel-level math.** You can create images from scratch using `Vips::Image.xyz()`, normalize coordinate bands, and do arithmetic to generate gradients, patterns, or anything you can express as a function of (x, y).
- **Pango text rendering.** `Vips::Image.text()` accepts Pango markup, which means you get font control, colors, sizes, and line wrapping. No need to calculate bounding boxes or deal with font metrics manually.
- **Compositing.** Layer images on top of each other with alpha blending, just like you would in Photoshop. The `.composite()` method handles it.

That's enough to build a complete OG image generator: a gradient background, some text, and a logo.

## The generator

The core class takes an organization and optional title/subtitle overrides. It builds a 1200×630 canvas (the standard OG image size), layers on a gradient background, composites the org's logo, and renders the title and subtitle.

```ruby
module OgImage
  class Generator
    WIDTH = 1200
    HEIGHT = 630

    def initialize(organization:, title: nil, subtitle: nil, feature_image: nil)
      @organization = organization
      @title = title || organization.name
      @subtitle = subtitle || organization.tagline
      @feature_image = feature_image
      @colors = ThemeColors.for(organization.theme.presence || "light")
    end

    def generate
      canvas = build_background
      canvas = composite_logo(canvas)
      canvas = composite_title(canvas)
      canvas = composite_subtitle(canvas)
      canvas.write_to_buffer(".png")
    end
  end
end
```

Each step returns a new canvas with the layer composited on top. At the end, `.write_to_buffer(".png")` serializes the whole thing to a PNG byte string.

## Building gradients with pixel math

This is the part that surprised me. You can build a smooth horizontal gradient without any image library "gradient" API, just by doing math on pixel coordinates.

`Vips::Image.xyz(width, height)` creates a two-band image where band 0 is the X coordinate and band 1 is the Y coordinate of each pixel. Extract band 0, divide by the width, and you get a value that goes from 0.0 on the left to 1.0 on the right. That's your interpolation factor.

```ruby
def build_gradient(left_color, right_color)
  gradient = Vips::Image.xyz(WIDTH, HEIGHT)
  x_norm = gradient.extract_band(0) / WIDTH.to_f

  channels = 3.times.map do |i|
    diff = right_color[i] - left_color[i]
    (x_norm * diff + left_color[i]).cast(:uchar)
  end

  channels[0].bandjoin(channels[1..])
end
```

For each RGB channel, you calculate `left + (right - left) * t` where `t` is the normalized X position. Cast to unsigned char (0–255), join the three channels together, and you have a smooth gradient image. The whole thing runs in a few milliseconds because vips operations are lazy and pipeline-optimized.

The gradient colors come from the organization's theme. I darken the primary color for the left edge and blend the base color with the primary for the right:

```ruby
def gradient_colors
  primary = hex_to_rgb(@colors.primary)
  base = hex_to_rgb(@colors.base_100)

  left = darken(primary, 0.7)
  right = blend(base, primary, 0.15)
  [left, right]
end
```

`darken` reduces each channel by a factor. `blend` mixes two colors: `base * (1 - amount) + overlay * amount`. Simple color math that produces a decent-looking gradient for any theme.

## Text rendering with Pango

Vips supports Pango markup through `Vips::Image.text()`. You pass it a string with Pango XML tags, and it returns a single-band image (the alpha mask of the rendered text). To get colored text, you build an RGB image from the desired color and attach the alpha mask.

```ruby
def render_text(content, size:, color:, width:)
  escaped = content
    .gsub("&", "&amp;")
    .gsub("<", "&lt;")
    .gsub(">", "&gt;")

  markup = "<span foreground='#{color}' size='#{size * 1024}'>#{escaped}</span>"
  alpha = Vips::Image.text(markup, width: width, dpi: 72, align: :centre)

  rgb = hex_to_rgb(color)
  colored = alpha.new_from_image(rgb).cast(:uchar).copy(interpretation: :srgb)
  colored.bandjoin(alpha)
end
```

Pango sizes are in units of 1/1024th of a point, so you multiply your desired point size by 1024. The `width:` parameter controls line wrapping. If the title is too long to fit in one line, Pango wraps it automatically.

One thing to watch: you have to XML-escape the text content. Organization names can contain ampersands, angle brackets, or other characters that break Pango's markup parser. I learned this when an org called "Arts & Culture" produced a blank title.

Compositing the text onto the canvas:

```ruby
def composite_title(canvas)
  text = render_text(@title, size: 52, color: @colors.base_content, width: WIDTH - 160)
  return canvas unless text

  x = (WIDTH - text.width) / 2
  y = @organization.icon.attached? ? 270 : 220

  canvas = ensure_alpha(canvas)
  canvas.composite(text, :over, x: [x], y: [y]).flatten
end
```

The Y offset adjusts based on whether there's a logo above the title. Centering is just `(canvas_width - text_width) / 2`. The `.flatten()` call at the end removes the alpha channel, merging everything into a solid RGB image.

## Compositing the logo

If the organization has an icon uploaded via Active Storage, it gets placed centered above the title:

```ruby
def composite_logo(canvas)
  return canvas unless @organization.icon.attached?

  icon_data = @organization.icon.download
  icon = Vips::Image.new_from_buffer(icon_data, "")
  icon = icon.thumbnail_image(80, height: 80, crop: :centre)

  if icon.bands == 3
    white_alpha = Vips::Image.black(icon.width, icon.height)
      .new_from_image([255]).cast(:uchar)
    icon = icon.bandjoin(white_alpha)
  end

  x = (WIDTH - icon.width) / 2
  canvas = ensure_alpha(canvas)
  canvas.composite(icon, :over, x: [x], y: [160]).flatten
rescue StandardError
  canvas
end
```

The `thumbnail_image` call resizes and center-crops to 80×80. If the uploaded image doesn't have an alpha channel (RGB instead of RGBA), a fully opaque alpha band is added before compositing. The rescue catches anything from corrupt uploads to missing files, falling back to no logo rather than crashing.

## Feature image backgrounds

For pages that have a banner photo (events, activities, certain posts), the gradient gets replaced with the actual image, darkened for text readability:

```ruby
def build_feature_background(image_data)
  img = Vips::Image.new_from_buffer(image_data, "")
  img = img.thumbnail_image(WIDTH, height: HEIGHT, crop: :centre)

  overlay = img.new_from_image([0, 0, 0]).cast(:uchar)
  alpha = img.new_from_image([160]).cast(:uchar)
  dark = overlay.bandjoin(alpha)

  img = ensure_alpha(img)
  img.composite(dark, :over).flatten
end
```

A black overlay with alpha 160 (roughly 63% opacity) goes on top of the image. That's dark enough for white text to be readable on any photo, without making the image unrecognizable.

## Per-organization theming

The platform uses daisyUI themes. Each organization picks a theme (light, dark, cupcake, nord, etc.), and that determines their color palette across the entire frontend. The OG image generator uses the same colors.

A `ThemeColors` class maps each daisyUI theme name to four colors using `Data.define`:

```ruby
module OgImage
  class ThemeColors
    Colors = Data.define(:base_100, :base_content, :primary, :primary_content)

    THEMES = {
      "light" => Colors.new(
        base_100: "#ffffff", base_content: "#2a323c",
        primary: "#570df8", primary_content: "#e8d5f5"
      ),
      "nord" => Colors.new(
        base_100: "#eceff4", base_content: "#2e3440",
        primary: "#5e81ac", primary_content: "#d8dee9"
      ),
      # ... 12 themes total
    }.freeze

    def self.for(theme_name)
      THEMES.fetch(theme_name, THEMES["light"])
    end
  end
end
```

When a new org signs up and picks the "autumn" theme, their OG images automatically get warm, earthy gradient tones. When they switch to "nord," the images shift to cool blues. No manual color configuration needed.

The gradient color math makes this work. Instead of hardcoding gradient stops, the generator derives them from the theme's primary and base colors. Darken the primary for depth, blend it with the background for a subtle fade. The formula produces reasonable results across all twelve themes without per-theme tuning.

## Caching

OG images don't change often, but they're requested frequently. Every social media crawler, every link preview, every share hits the endpoint. The caching strategy has two layers.

On the Rails side, Solid Cache stores the generated PNG for 24 hours:

```ruby
def show
  cache_key = [
    "og_image",
    current_organization.cache_key_with_version,
    params[:page],
    params[:slug]
  ].join("/")

  png_data = Rails.cache.fetch(cache_key, expires_in: 24.hours) do
    build_generator.generate
  end

  send_data png_data,
    type: "image/png",
    disposition: "inline"
end
```

The cache key includes `cache_key_with_version`, which changes whenever the organization record is updated. So if someone changes the org name, logo, or theme, the cached image is automatically invalidated.

On the HTTP side, `Cache-Control: public, max-age=86400` tells browsers and CDNs to cache the response for 24 hours. Between Solid Cache and HTTP caching, the generator rarely runs more than once per page per day.

For the platform's own OG image (a static image with fixed branding), the cache TTL bumps to 7 days with a versioned key that I manually increment when the design changes.

## The controller and routes

The controller is minimal. It resolves what type of page needs an image, finds the relevant record, and passes it to the generator:

```ruby
module Public
  class OgImagesController < PublicController
    def show
      # ... caching logic above ...
    end

    private

    def build_generator
      case params[:page]
      when "event"
        event = current_organization.events.find_by!(slug: params[:slug])
        OgImage::Generator.new(
          organization: current_organization,
          title: event.name,
          subtitle: event.short_description,
          feature_image: event.banner_image
        )
      when "post"
        post = current_organization.posts.find_by!(slug: params[:slug])
        OgImage::Generator.new(
          organization: current_organization,
          title: post.title,
          feature_image: post.cover_image
        )
      else
        OgImage::Generator.new(organization: current_organization)
      end
    end
  end
end
```

A single route handles it:

```ruby
get "og-image" => "public/og_images#show", as: :og_image
```

Views reference it with query params: `og_image_url(page: "event", slug: event.slug)`. The meta tags helper falls through a priority list: explicit override → attached cover image → generated OG image → platform default.

## Gotchas

**Pango markup is XML.** I said this already, but it cost me real time. If the text has an unescaped `&` or `<`, Pango returns an empty image. No error, no exception. You just get a blank space where the title should be. Always escape.

**Alpha channel management.** Vips compositing requires both images to have an alpha channel. If your gradient is RGB (3 bands) and your text is RGBA (4 bands), compositing fails. The `ensure_alpha` helper adds a fully opaque alpha band to any 3-band image. I call it before every composite operation because it's easy to forget which images have alpha and which don't.

```ruby
def ensure_alpha(image)
  return image if image.bands == 4

  alpha = image.new_from_image([255]).cast(:uchar)
  image.bandjoin(alpha)
end
```

**Font availability.** Pango uses whatever fonts are installed on the system. In development on macOS, you get the system font library. In a Docker container, you get whatever the base image includes. My Dockerfile adds `fonts-liberation` for a clean sans-serif that looks consistent across environments. Without it, Pango falls back to a generic monospace font that makes the OG images look like terminal screenshots.

```dockerfile
RUN apt-get install -y fonts-liberation
```

**Memory with large feature images.** Vips is streaming and lazy, so it handles large images well. But if someone uploads a 30MB TIFF as their event banner, `new_from_buffer` loads the whole thing into memory before thumbnailing. For Active Storage attachments, this hasn't been a problem in practice (they're already validated and resized on upload), but it's worth knowing if you're processing arbitrary input.

## What it looks like in practice

The generator produces images that look intentional, not generated. The gradient matches the org's brand colors. The logo is centered and properly sized. The text wraps cleanly within the bounds. When the page has a feature photo, it shows through a dark overlay with the title on top.

For a platform with twelve themes and hundreds of organizations, each social share card looks like it belongs to that org. And it's all generated on the fly from a few hundred lines of Ruby, cached aggressively, with no external dependencies beyond what Rails already ships with.

I probably spent more time tweaking the gradient math and text positioning than I would have spent setting up Puppeteer. But the result is a self-contained Ruby module that runs anywhere Rails runs, generates images in under 100ms, and doesn't need a headless browser, a Node.js runtime, or a third-party API. For a Rails 8 app that's otherwise Node-free, that felt like the right call.
