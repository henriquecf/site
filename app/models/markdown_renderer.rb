class MarkdownRenderer < Redcarpet::Render::HTML
  def block_code(code, language)
    language ||= "text"
    lexer = Rouge::Lexer.find_fancy(language) || Rouge::Lexers::PlainText.new
    formatter = Rouge::Formatters::HTML.new
    %(<pre class="highlight"><code class="language-#{language}">#{formatter.format(lexer.lex(code))}</code></pre>)
  end
end
