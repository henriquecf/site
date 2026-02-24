class Message < ApplicationRecord
  acts_as_message tool_calls_foreign_key: :message_id

  broadcasts_to ->(message) { "chat_#{message.chat_id}" }

  # Groq does not support reasoning_content in conversation history,
  # so strip thinking fields to avoid errors on subsequent turns.
  after_save :clear_thinking_fields, if: -> { thinking_text.present? || thinking_signature.present? }

  def broadcast_append_chunk(content)
    broadcast_append_to "chat_#{chat_id}",
      target: "message_#{id}_content",
      partial: "messages/content",
      locals: { content: content }
  end

  def broadcast_rendered_content
    reload
    broadcast_replace_to "chat_#{chat_id}",
      target: "message_#{id}_content",
      partial: "messages/rendered_content",
      locals: { message: self }
  end

  private

  def clear_thinking_fields
    update_columns(thinking_text: nil, thinking_signature: nil)
  end
end
