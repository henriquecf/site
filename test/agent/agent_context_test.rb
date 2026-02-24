require "test_helper"

class AgentContextTest < ActiveSupport::TestCase
  test "system_prompt includes llms.txt content" do
    prompt = AgentContext.system_prompt
    assert_includes prompt, "Henrique Cardoso de Faria"
    assert_includes prompt, "Ruby on Rails"
    assert_includes prompt, "BSPK"
  end

  test "system_prompt includes persona instructions" do
    prompt = AgentContext.system_prompt
    assert_includes prompt, "conversational AI assistant"
    assert_includes prompt, "elo.henrique@gmail.com"
  end

  test "system_prompt includes tool usage guidelines" do
    prompt = AgentContext.system_prompt
    assert_includes prompt, "tools available"
    assert_includes prompt, "blog post"
  end
end
