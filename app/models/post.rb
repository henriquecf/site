class Post < ApplicationRecord
  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :body, presence: true

  scope :published, -> { where.not(published_at: nil).where(published_at: ..Time.current).order(published_at: :desc) }

  before_validation :generate_slug, on: :create

  def published?
    published_at.present? && published_at <= Time.current
  end

  def body_html
    markdown = Redcarpet::Markdown.new(
      MarkdownRenderer.new(with_toc_data: true),
      fenced_code_blocks: true,
      autolink: true,
      tables: true,
      strikethrough: true,
      footnotes: true,
      highlight: true
    )
    markdown.render(body).html_safe
  end

  def x_first_tweet
    x_body&.split("---")&.first&.strip
  end

  def x_second_tweet
    x_body&.split("---")&.second&.strip
  end

  private

  def generate_slug
    self.slug = title.parameterize if title.present? && slug.blank?
  end
end
