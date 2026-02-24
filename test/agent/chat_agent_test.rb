require "test_helper"

class ChatAgentTest < ActiveSupport::TestCase
  setup do
    chat = Chat.new(session_id: "test-session")
    chat.assume_model_exists = true
    chat.provider = :openai
    chat.save!
    @chat = chat
  end

  test "responds to a greeting about Henrique" do
    VCR.use_cassette("agent/greeting") do
      @chat
        .with_instructions(AgentContext.system_prompt)
        .with_tools(SearchBlogPostsTool, GetBlogPostTool, SearchSiteContentTool)
        .ask("Hi! What does Henrique do?")

      response = @chat.messages.where(role: "assistant").last
      assert response.content.present?, "Expected a non-empty assistant response"
      assert_match(/engineer|software|rails/i, response.content)
    end
  end

  test "knows about Henrique's skills" do
    VCR.use_cassette("agent/skills") do
      @chat
        .with_instructions(AgentContext.system_prompt)
        .with_tools(SearchBlogPostsTool, GetBlogPostTool, SearchSiteContentTool)
        .ask("What programming languages and frameworks does Henrique work with?")

      response = @chat.messages.where(role: "assistant").last
      assert response.content.present?
      assert_match(/ruby|rails|elixir/i, response.content)
    end
  end

  test "knows about BSPK work" do
    VCR.use_cassette("agent/bspk") do
      @chat
        .with_instructions(AgentContext.system_prompt)
        .with_tools(SearchBlogPostsTool, GetBlogPostTool, SearchSiteContentTool)
        .ask("Tell me about Henrique's work at BSPK")

      response = @chat.messages.where(role: "assistant").last
      assert response.content.present?
      assert_match(/bspk|ai|luxury/i, response.content)
    end
  end

  test "directs hiring inquiries to email" do
    VCR.use_cassette("agent/hiring") do
      @chat
        .with_instructions(AgentContext.system_prompt)
        .with_tools(SearchBlogPostsTool, GetBlogPostTool, SearchSiteContentTool)
        .ask("I want to hire Henrique for a Rails project. How do I get in touch?")

      response = @chat.messages.where(role: "assistant").last
      assert response.content.present?
      assert_match(/elo\.henrique@gmail\.com/i, response.content)
    end
  end

  test "answers questions about blog and writing" do
    VCR.use_cassette("agent/blog_question") do
      @chat
        .with_instructions(AgentContext.system_prompt)
        .ask("Does Henrique write about technical topics?")

      response = @chat.messages.where(role: "assistant").last
      assert response.content.present?
    end
  end
end
