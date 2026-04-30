require "yaml"
require "ostruct"

class Profile
  PATH = Rails.root.join("config", "profile.yml")

  class << self
    def data
      @data ||= YAML.safe_load_file(PATH, permitted_classes: [ Date, Time ]).deep_symbolize_keys
    end

    def reload!
      @data = nil
      data
    end

    def identity = OpenStruct.new(data[:identity])
    def summary = data[:summary].to_s.strip
    def experience = data[:experience].to_a
    def skills = data[:skills] || {}
    def projects = data[:projects].to_a
    def community = data[:community].to_a
    def education = data[:education].to_a
    def languages = data[:languages].to_a
    def writing = OpenStruct.new(data[:writing] || {})
  end
end
