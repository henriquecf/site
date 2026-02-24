class ChatsController < ApplicationController
  def show
    @chat = find_or_create_chat
    @new_chat = @chat.messages.empty?
    @message = @chat.messages.build
  end

  def destroy
    Chat.for_session(session_id).destroy_all
    redirect_to chat_path
  end

  private

  def find_or_create_chat
    Chat.for_session(session_id).order(created_at: :desc).first || create_chat
  end

  def create_chat
    chat = Chat.new(session_id: session_id)
    chat.assume_model_exists = true
    chat.provider = :openai
    chat.save!
    chat
  end

  def session_id
    session[:chat_session_id] ||= SecureRandom.uuid
  end
end
