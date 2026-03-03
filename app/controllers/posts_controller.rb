class PostsController < ApplicationController
  def index
    @posts = Post.published
    fresh_when @posts
  end

  def show
    @post = Post.published.find_by!(slug: params[:slug])
    fresh_when @post
  end

  def share
    @post = Post.published.find_by!(slug: params[:slug])
  end

  def feed
    @posts = Post.published
    fresh_when @posts

    respond_to do |format|
      format.atom
    end
  end
end
