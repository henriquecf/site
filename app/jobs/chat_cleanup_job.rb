class ChatCleanupJob < ApplicationJob
  def perform
    Chat.where(created_at: ...30.days.ago).destroy_all
  end
end
