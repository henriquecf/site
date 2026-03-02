class SitemapsController < ApplicationController
  skip_after_action :track_page_view

  def show
    @posts = Post.published
    expires_in 1.hour, public: true
  end
end
