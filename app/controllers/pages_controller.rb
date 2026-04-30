class PagesController < ApplicationController
  def home
    @recent_posts = Post.published.limit(4)
  end

  def uses
  end

  def resume
    @profile = Profile
    @recent_posts = Post.published.limit(5)
  end
end
