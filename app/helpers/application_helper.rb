module ApplicationHelper
  def render_markdown(text)
    return "" if text.blank?

    markdown = Redcarpet::Markdown.new(
      MarkdownRenderer.new(with_toc_data: true),
      fenced_code_blocks: true,
      autolink: true,
      tables: true,
      strikethrough: true
    )
    markdown.render(text).html_safe
  end
end
