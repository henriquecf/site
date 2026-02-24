class ChatResponseJob < ApplicationJob
  TOOLS = [ SearchBlogPostsTool, GetBlogPostTool, SearchSiteContentTool ].freeze

  def perform(chat_id, content)
    chat = Chat.find(chat_id)

    chat
      .with_instructions(AgentContext.system_prompt)
      .with_tools(*TOOLS)
      .ask(content) do |chunk|
        if chunk.content.present?
          chat.messages.where(role: "assistant").last
            &.broadcast_append_chunk(chunk.content)
        end
      end

    chat.messages.where(role: "assistant").last
      &.broadcast_rendered_content
  rescue => e
    Rails.logger.error("ChatResponseJob failed: #{e.message}")
  end
end
