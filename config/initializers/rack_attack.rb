Rack::Attack.throttle("chat/messages", limit: 20, period: 1.hour) do |req|
  if req.path == "/chat/messages" && req.post?
    req.session[:chat_session_id]
  end
end
