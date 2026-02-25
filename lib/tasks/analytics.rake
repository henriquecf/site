namespace :analytics do
  desc "Dashboard: overview of visits, page views, and top pages"
  task dashboard: :environment do
    puts "\n📊 Analytics Dashboard"
    puts "=" * 60

    # Overall stats
    total_visits = Ahoy::Visit.count
    total_views = Ahoy::Event.where(name: "$view").count
    unique_visitors = Ahoy::Visit.distinct.count(:visitor_token)

    puts "\n  Total visits:      #{total_visits}"
    puts "  Unique visitors:   #{unique_visitors}"
    puts "  Total page views:  #{total_views}"

    if total_visits > 0
      puts "  Avg views/visit:   #{(total_views.to_f / total_visits).round(1)}"
    end

    # Today / this week / this month
    puts "\n── Period Breakdown ─────────────────────────────────────"
    {
      "Today" => Time.current.beginning_of_day..,
      "This week" => Time.current.beginning_of_week..,
      "This month" => Time.current.beginning_of_month..
    }.each do |label, range|
      visits = Ahoy::Visit.where(started_at: range).count
      views = Ahoy::Event.where(name: "$view", time: range).count
      printf "  %-14s %6d visits  %6d views\n", label, visits, views
    end

    # Top pages
    puts "\n── Top 10 Pages ────────────────────────────────────────"
    top_pages = Ahoy::Event.where(name: "$view")
      .pluck(:properties)
      .map { |p| p.is_a?(String) ? JSON.parse(p) : p }
      .group_by { |p| p["page"] }
      .transform_values(&:count)
      .sort_by { |_, count| -count }
      .first(10)

    if top_pages.any?
      max = top_pages.first[1]
      top_pages.each do |page, count|
        bar = "█" * (count.to_f / max * 30).ceil
        printf "  %-30s %5d  %s\n", page.truncate(30), count, bar
      end
    else
      puts "  No data yet."
    end

    puts
  end

  desc "Daily visits chart for the last 30 days"
  task daily: :environment do
    puts "\n📈 Daily Visits (last 30 days)"
    puts "=" * 60

    days = (29.days.ago.to_date..Date.current).to_a
    daily = Ahoy::Visit.where(started_at: 30.days.ago..)
      .group_by { |v| v.started_at.to_date }
      .transform_values(&:count)

    max = daily.values.max || 1

    days.each do |day|
      count = daily[day] || 0
      bar = count > 0 ? "█" * (count.to_f / max * 40).ceil : ""
      marker = day == Date.current ? " ◀ today" : ""
      printf "  %s  %4d  %s%s\n", day.strftime("%b %d %a"), count, bar, marker
    end

    puts
  end

  desc "Top referrers"
  task referrers: :environment do
    puts "\n🔗 Top Referrers"
    puts "=" * 60

    referrers = Ahoy::Visit.where.not(referring_domain: [ nil, "" ])
      .group(:referring_domain)
      .order("count_all DESC")
      .limit(15)
      .count

    if referrers.any?
      max = referrers.values.max
      referrers.each do |domain, count|
        bar = "█" * (count.to_f / max * 30).ceil
        printf "  %-30s %5d  %s\n", domain.truncate(30), count, bar
      end
    else
      puts "  No referrer data yet."
    end

    puts
  end

  desc "Browser and device breakdown"
  task devices: :environment do
    puts "\n💻 Browsers"
    puts "=" * 60

    browsers = Ahoy::Visit.where.not(browser: [ nil, "" ])
      .group(:browser).order("count_all DESC").limit(10).count

    if browsers.any?
      max = browsers.values.max
      browsers.each do |browser, count|
        bar = "█" * (count.to_f / max * 30).ceil
        printf "  %-20s %5d  %s\n", browser.truncate(20), count, bar
      end
    end

    puts "\n📱 Device Types"
    puts "-" * 60

    devices = Ahoy::Visit.where.not(device_type: [ nil, "" ])
      .group(:device_type).order("count_all DESC").count

    if devices.any?
      max = devices.values.max
      devices.each do |device, count|
        bar = "█" * (count.to_f / max * 30).ceil
        printf "  %-20s %5d  %s\n", device, count, bar
      end
    else
      puts "  No device data yet."
    end

    puts "\n🖥  Operating Systems"
    puts "-" * 60

    oses = Ahoy::Visit.where.not(os: [ nil, "" ])
      .group(:os).order("count_all DESC").limit(10).count

    if oses.any?
      max = oses.values.max
      oses.each do |os, count|
        bar = "█" * (count.to_f / max * 30).ceil
        printf "  %-20s %5d  %s\n", os.truncate(20), count, bar
      end
    end

    puts
  end

  desc "Hourly traffic pattern for today"
  task hourly: :environment do
    puts "\n🕐 Hourly Traffic (today)"
    puts "=" * 60

    events = Ahoy::Event.where(name: "$view", time: Time.current.beginning_of_day..)
      .group_by { |e| e.time.hour }
      .transform_values(&:count)

    max = events.values.max || 1

    (0..23).each do |hour|
      count = events[hour] || 0
      bar = count > 0 ? "█" * (count.to_f / max * 40).ceil : ""
      marker = hour == Time.current.hour ? " ◀ now" : ""
      printf "  %02d:00  %4d  %s%s\n", hour, count, bar, marker
    end

    puts
  end

  desc "Show all analytics reports"
  task all: [ :dashboard, :daily, :referrers, :devices, :hourly ]
end
