class LlmsController < ApplicationController
  skip_after_action :track_page_view

  def show
    @base_content = Rails.root.join("app/content/llms_base.txt").read
    @posts = Post.published
  end

  def full
    @base_content = Rails.root.join("app/content/llms_base.txt").read
    @posts = Post.published
  end
end
