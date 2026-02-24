require "test_helper"

class SearchBlogPostsToolTest < ActiveSupport::TestCase
  test "finds published posts matching query" do
    result = SearchBlogPostsTool.new.execute(query: "AI")
    assert result[:results].any?
    assert_equal "Building AI Features with Ruby on Rails", result[:results].first[:title]
  end

  test "returns empty results for no match" do
    result = SearchBlogPostsTool.new.execute(query: "nonexistent-topic-xyz")
    assert_empty result[:results]
    assert_includes result[:message], "No posts found"
  end

  test "does not return unpublished posts" do
    result = SearchBlogPostsTool.new.execute(query: "Draft")
    assert_empty result[:results]
  end
end

class GetBlogPostToolTest < ActiveSupport::TestCase
  test "returns full post content by slug" do
    result = GetBlogPostTool.new.execute(slug: "building-ai-features-rails")
    assert_equal "Building AI Features with Ruby on Rails", result[:title]
    assert result[:body].present?
  end

  test "returns error for nonexistent slug" do
    result = GetBlogPostTool.new.execute(slug: "does-not-exist")
    assert_equal "Post not found", result[:error]
  end

  test "does not return unpublished posts" do
    result = GetBlogPostTool.new.execute(slug: "draft-post")
    assert_equal "Post not found", result[:error]
  end
end

class SearchSiteContentToolTest < ActiveSupport::TestCase
  test "finds sections matching query" do
    result = SearchSiteContentTool.new.execute(query: "BSPK")
    assert result[:results].any?
    assert result[:results].any? { |s| s.include?("BSPK") }
  end

  test "returns empty for no match" do
    result = SearchSiteContentTool.new.execute(query: "xyznonexistent")
    assert_empty result[:results]
  end
end
