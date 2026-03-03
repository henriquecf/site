atom_feed(
  language: "en-US",
  root_url: root_url,
  url: blog_feed_url
) do |feed|
  feed.title "Blog — Henrique Cardoso de Faria"
  feed.subtitle "Writing about Ruby on Rails, Elixir, AI, and software engineering."
  feed.updated @posts.first&.modified_at || Time.current
  feed.author do |author|
    author.name "Henrique Cardoso de Faria"
    author.uri root_url
  end

  @posts.each do |post|
    feed.entry(
      post,
      id: "tag:hencf.org,#{post.published_at.to_date}:#{post.slug}",
      url: post_url(slug: post.slug),
      published: post.published_at,
      updated: post.modified_at
    ) do |entry|
      entry.title post.title
      entry.summary post.description_or_fallback
      entry.content post.body_html, type: "html"
      entry.author do |author|
        author.name "Henrique Cardoso de Faria"
      end
    end
  end
end
