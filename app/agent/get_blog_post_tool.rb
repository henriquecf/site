class GetBlogPostTool < RubyLLM::Tool
  description "Get the full content of a specific blog post by its slug"
  param :slug, desc: "The blog post slug (URL identifier)"

  def execute(slug:)
    post = Post.published.find_by(slug: slug)
    return { error: "Post not found" } unless post

    { title: post.title, published_at: post.published_at.to_date.to_s, body: post.body }
  end
end
