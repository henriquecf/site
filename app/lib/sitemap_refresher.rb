class SitemapRefresher
  SITEMAPS_DIR = Rails.root.join("public", "sitemaps")
  HOST = "https://hencf.org"

  def self.generate_all
    new.generate_all
  end

  def generate_all
    SitemapGenerator::Sitemap.default_host = HOST
    SitemapGenerator::Sitemap.public_path = SITEMAPS_DIR.to_s
    SitemapGenerator::Sitemap.sitemaps_path = "site"
    SitemapGenerator::Sitemap.compress = false
    SitemapGenerator::Sitemap.create_index = false
    SitemapGenerator::Sitemap.namer = SitemapGenerator::SimpleNamer.new(:sitemap)

    SitemapGenerator::Sitemap.create do
      group(filename: :static, sitemaps_path: "site") do
        add "/", changefreq: "weekly", priority: 1.0
        add "/blog", changefreq: "weekly", priority: 0.9,
            lastmod: Post.published.first&.modified_at
        add "/uses", changefreq: "monthly", priority: 0.5

        Post.published.find_each do |post|
          add "/blog/#{post.slug}", changefreq: "monthly", priority: 0.7,
              lastmod: post.modified_at
        end
      end
    end

    write_index
  end

  private

  def write_index
    xml = +""
    xml << %(<?xml version="1.0" encoding="UTF-8"?>\n)
    xml << %(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
    xml << %(  <sitemap>\n    <loc>#{HOST}/sitemaps/static.xml</loc>\n  </sitemap>\n)
    xml << %(</sitemapindex>\n)

    dir = SITEMAPS_DIR.join("site")
    FileUtils.mkdir_p(dir)
    File.write(dir.join("sitemap.xml"), xml)
  end
end
