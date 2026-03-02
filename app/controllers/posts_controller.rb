class PostsController < ApplicationController
  def index
    @posts = Post.published
  end

  def show
    @post = Post.published.find_by!(slug: params[:slug])
  end

  def share
    @post = Post.published.find_by!(slug: params[:slug])
  end

  def feed
    @posts = Post.published

    respond_to do |format|
      format.atom
    end
  end
end
