class AddContentModifiedAtToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :content_modified_at, :datetime
  end
end
