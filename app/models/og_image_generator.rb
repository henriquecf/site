class OgImageGenerator
  WIDTH = 1200
  HEIGHT = 630
  OUTPUT_DIR = Rails.root.join("public/og")

  BG_COLOR = "#FDFBF7"
  TEXT_COLOR = "#1E1C1A"
  ACCENT_COLOR = "#5B7F6E"

  def self.call(post)
    new(post).generate
  end

  def initialize(post)
    @post = post
  end

  def generate
    return url_path if File.exist?(output_path)

    FileUtils.mkdir_p(OUTPUT_DIR)
    cleanup_stale_images

    image = render_image
    image.pngsave(output_path.to_s)

    url_path
  end

  private

  def solid_image(width, height, hex_color)
    r, g, b = hex_to_rgb(hex_color)
    Vips::Image.black(width, height).new_from_image([ r, g, b ]).copy(interpretation: :srgb)
  end

  def render_image
    bg = solid_image(WIDTH, HEIGHT, BG_COLOR)

    # Accent stripe at top
    stripe = solid_image(WIDTH, 8, ACCENT_COLOR).bandjoin(255)
    bg = bg.composite(stripe, :over, x: [ 0 ], y: [ 0 ])

    # Title text
    title_text = Vips::Image.text(
      escape_markup(@post.title),
      width: WIDTH - 160,
      height: 320,
      font: "sans bold 48",
      rgba: true
    )
    # Colorize the title text
    title_colored = colorize(title_text, TEXT_COLOR)
    bg = bg.composite(title_colored, :over, x: [ 80 ], y: [ 120 ])

    # Author text
    author_text = Vips::Image.text(
      "Henrique Cardoso de Faria · hencf.org",
      font: "sans 28",
      rgba: true
    )
    author_colored = colorize(author_text, ACCENT_COLOR)
    bg = bg.composite(author_colored, :over, x: [ 80 ], y: [ HEIGHT - 100 ])

    bg
  end

  def colorize(text_image, hex_color)
    r, g, b = hex_to_rgb(hex_color)
    alpha = text_image.extract_band(3)
    colored = alpha.new_from_image([ r, g, b ]).copy(interpretation: :srgb)
    colored.bandjoin(alpha)
  end

  def hex_to_rgb(hex)
    hex = hex.delete("#")
    [ hex[0..1], hex[2..3], hex[4..5] ].map { |c| c.to_i(16) }
  end

  def escape_markup(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  def cleanup_stale_images
    Dir[OUTPUT_DIR.join("#{@post.slug}-*.png")].each { |f| File.delete(f) }
  end

  def title_digest
    Digest::MD5.hexdigest(@post.title)[0, 8]
  end

  def filename
    "#{@post.slug}-#{title_digest}.png"
  end

  def output_path
    OUTPUT_DIR.join(filename)
  end

  def url_path
    "https://hencf.org/og/#{filename}"
  end
end
