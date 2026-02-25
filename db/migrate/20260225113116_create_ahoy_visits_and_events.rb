class CreateAhoyVisitsAndEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :ahoy_visits do |t|
      t.string :visit_token
      t.string :visitor_token

      # standard
      t.string :ip
      t.text :user_agent
      t.text :referrer
      t.string :referring_domain
      t.text :landing_page

      # technology
      t.string :browser
      t.string :os
      t.string :device_type

      # utm parameters
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign

      t.datetime :started_at
    end

    add_index :ahoy_visits, :visit_token, unique: true
    add_index :ahoy_visits, [:visitor_token, :started_at]

    create_table :ahoy_events do |t|
      t.references :visit

      t.string :name
      t.text :properties
      t.datetime :time
    end

    add_index :ahoy_events, [:name, :time]
  end
end
