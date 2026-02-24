require "test_helper"

class ChatFlowTest < ActionDispatch::IntegrationTest
  test "GET /chat creates a session-scoped chat" do
    get chat_path
    assert_response :success
    assert_select "h1", "Chat with an AI assistant"
    assert_select ".chat-suggestion", count: 4
    assert session[:chat_session_id].present?
  end

  test "GET /chat returns same chat for same session" do
    get chat_path
    first_session_id = session[:chat_session_id]

    get chat_path
    assert_equal first_session_id, session[:chat_session_id]
    assert_equal 1, Chat.for_session(first_session_id).count
  end

  test "POST /chat/messages with empty content does not enqueue job" do
    get chat_path

    assert_no_enqueued_jobs do
      post chat_messages_path, params: { content: "" }
    end
  end

  test "POST /chat/messages enqueues ChatResponseJob" do
    get chat_path

    assert_enqueued_with(job: ChatResponseJob) do
      post chat_messages_path, params: { content: "Hello" }, as: :turbo_stream
    end
  end

  test "chat page has nav with expected links" do
    get chat_path
    assert_select ".nav-links a[href='/blog']", "Blog"
    assert_select ".nav-links a[href='/#about']", "About"
  end
end
