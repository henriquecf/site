namespace :posts do
  desc "Load blog posts from db/posts/*.yml into the database"
  task load: :environment do
    posts_dir = Rails.root.join("db/posts")

    Dir[posts_dir.join("*.yml")].each do |yml_path|
      slug = File.basename(yml_path, ".yml")

      if Post.exists?(slug: slug)
        puts "Skipping #{slug} (already exists)"
        next
      end

      data = YAML.safe_load_file(yml_path, permitted_classes: [ Time ])
      md_path = posts_dir.join("#{slug}.md")

      unless File.exist?(md_path)
        puts "Skipping #{slug} (missing #{slug}.md)"
        next
      end

      Post.create!(
        title: data.fetch("title"),
        slug: slug,
        body: File.read(md_path),
        published_at: data["published_at"],
        linkedin_body: data["linkedin_body"]&.strip,
        x_body: data["x_body"]&.strip
      )

      puts "Created #{slug}"
    end
  end
end
