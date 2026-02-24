ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "vcr"
require "webmock/minitest"

VCR.configure do |config|
  config.cassette_library_dir = "test/cassettes"
  config.hook_into :webmock
  config.filter_sensitive_data("<GROQ_API_KEY>") { ENV["GROQ_API_KEY"] || Rails.application.credentials.groq_api_key }
  config.default_cassette_options = { record: :once, match_requests_on: [ :method, :uri, :body ] }
  config.allow_http_connections_when_no_cassette = false
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
