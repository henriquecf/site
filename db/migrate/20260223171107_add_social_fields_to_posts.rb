class AddSocialFieldsToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :linkedin_body, :text
    add_column :posts, :x_body, :text
  end
end
