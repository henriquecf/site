class GenerateSitemapsJob < ApplicationJob
  queue_as :default

  def perform
    SitemapRefresher.generate_all
  end
end
