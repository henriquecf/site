class MessagesController < ApplicationController
  rate_limit to: 20, within: 1.hour, by: -> { session[:chat_session_id] }, with: -> { head :too_many_requests }

  def create
    @chat = Chat.for_session(session_id).order(created_at: :desc).first!

    if content.present?
      ChatResponseJob.perform_later(@chat.id, content)
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to chat_path }
    end
  end

  private

  def session_id
    session[:chat_session_id]
  end

  def content
    params[:content]
  end
end
