class Chat < ApplicationRecord
  acts_as_chat messages_foreign_key: :chat_id

  validates :session_id, presence: true

  scope :for_session, ->(session_id) { where(session_id: session_id) }
end
