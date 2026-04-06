class SitemapsController < ApplicationController
  skip_after_action :track_page_view

  def show
    path = SitemapRefresher::SITEMAPS_DIR.join("site", "sitemap.xml")

    if File.exist?(path)
      expires_in 1.hour, public: true
      response.headers["Last-Modified"] = File.mtime(path).httpdate
      send_file path, type: "application/xml", disposition: :inline
    else
      @posts = Post.published
      expires_in 1.hour, public: true
    end
  end

  def static
    path = SitemapRefresher::SITEMAPS_DIR.join("site", "static.xml")

    if File.exist?(path)
      expires_in 1.hour, public: true
      response.headers["Last-Modified"] = File.mtime(path).httpdate
      send_file path, type: "application/xml", disposition: :inline
    else
      head :not_found
    end
  end
end
