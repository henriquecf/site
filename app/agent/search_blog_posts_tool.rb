class SearchBlogPostsTool < RubyLLM::Tool
  description "Search blog posts by topic. Returns titles, dates, URLs, and excerpts."
  param :query, desc: "Topic or keywords to search for"

  def execute(query:)
    posts = Post.published.where("title LIKE :q OR body LIKE :q", q: "%#{query}%")
    return { results: [], message: "No posts found matching '#{query}'" } if posts.empty?

    {
      results: posts.map { |p|
        { title: p.title, url: "/blog/#{p.slug}", date: p.published_at.to_date.to_s, excerpt: p.body.truncate(500) }
      }
    }
  end
end
