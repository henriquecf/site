class SearchSiteContentTool < RubyLLM::Tool
  description "Search all site content (experience, skills, services, uses page, etc.) by keyword"
  param :query, desc: "Keywords to search for in site content"

  def execute(query:)
    content = Rails.root.join("public/llms.txt").read
    query_terms = query.downcase.split

    sections = content.split(/^## /).reject(&:blank?)
    matches = sections.select { |section|
      section_lower = section.downcase
      query_terms.any? { |term| section_lower.include?(term) }
    }

    return { results: [], message: "No content found matching '#{query}'" } if matches.empty?

    { results: matches.map { |section| "## #{section.strip}" } }
  end
end
