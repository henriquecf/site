xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  xml.url do
    xml.loc root_url
    xml.lastmod @posts.first&.modified_at&.iso8601
  end

  xml.url do
    xml.loc blog_url
    xml.lastmod @posts.first&.modified_at&.iso8601
  end

  xml.url do
    xml.loc uses_url
  end

  @posts.each do |post|
    xml.url do
      xml.loc post_url(slug: post.slug)
      xml.lastmod post.modified_at.iso8601
    end
  end
end
