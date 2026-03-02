class AddSeoFieldsToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :description, :text
    add_column :posts, :og_image_url, :string
  end
end
