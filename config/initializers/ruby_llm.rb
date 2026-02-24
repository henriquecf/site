RubyLLM.configure do |config|
  config.openai_api_key = ENV["GROQ_API_KEY"] || Rails.application.credentials.groq_api_key || "test-key"
  config.openai_api_base = "https://api.groq.com/openai/v1"
  config.default_model = "openai/gpt-oss-120b"

  config.use_new_acts_as = true
end
