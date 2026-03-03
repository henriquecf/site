xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  xml.url do
    xml.loc root_url
    xml.changefreq "monthly"
    xml.priority "1.0"
  end

  xml.url do
    xml.loc blog_url
    xml.changefreq "weekly"
    xml.priority "0.9"
  end

  xml.url do
    xml.loc uses_url
    xml.changefreq "monthly"
    xml.priority "0.5"
  end

  @posts.each do |post|
    xml.url do
      xml.loc post_url(slug: post.slug)
      xml.lastmod post.modified_at.iso8601
      xml.changefreq "monthly"
      xml.priority "0.8"
    end
  end
end
