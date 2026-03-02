namespace :og do
  desc "Generate OG images for all published posts"
  task generate: :environment do
    Post.published.find_each do |post|
      next if post.og_image_url.present?

      OgImageGenerator.call(post)
      puts "Generated OG image for #{post.slug}"
    end
  end
end
