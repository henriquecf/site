class PostsController < ApplicationController
  PER_PAGE = 10

  def index
    @all_posts = Post.published
    @posts = @all_posts
    @posts = @posts.search(params[:q]) if params[:q].present?

    page = [ (params[:page] || 1).to_i, 1 ].max
    @posts = @posts.offset((page - 1) * PER_PAGE).limit(PER_PAGE + 1)

    if @posts.size > PER_PAGE
      @posts = @posts.first(PER_PAGE)
      @next_page = page + 1
    end

    fresh_when @all_posts unless params[:q].present? || page > 1 || turbo_frame_request?
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
