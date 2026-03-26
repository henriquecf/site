I run a multi-tenant Rails 8 app on a single server with SQLite. Solid Cache for caching, Solid Queue for background jobs, and a separate database for Action Cable via Solid Cable. The primary database also has an `ahoy_events` table that tracks page views and cleans up after 90 days.

All of these churn data. Cache entries expire, jobs complete and get swept, old analytics rows get deleted. Normal stuff.

A few weeks ago I was checking disk usage and noticed the Pulse monitoring database had grown to 6.9 GB. I pulled up the actual data size:

```sql
SELECT page_count * page_size AS total_bytes,
       (page_count - freelist_count) * page_size AS used_bytes,
       freelist_count * page_size AS free_bytes
FROM pragma_page_count, pragma_page_size, pragma_freelist_count;
```

37 MB of actual data. 6.85 GB of empty space SQLite was holding onto.

## Why SQLite doesn't shrink

When you delete rows from a SQLite database, the pages those rows occupied get added to an internal freelist. They're marked as available for reuse, but they're never returned to the operating system. The file size stays the same.

This is by design. SQLite's default `auto_vacuum` mode is `NONE` (0). The database file is a single file on disk, and shrinking it means rewriting everything after the freed pages. That's expensive, so SQLite doesn't do it unless you ask.

If your application mostly grows (inserts outnumber deletes), this doesn't matter much. The free pages get reused by new inserts. But if your application churns data, deleting old rows on a schedule and inserting new ones, you end up with a file that reflects your peak historical data size, not your current data size.

Solid Cache is the worst offender. It writes and expires entries constantly. A cache database that holds 500 MB of active entries might have a 5 GB file because it once held 5 GB worth of entries before they expired.

## The three auto_vacuum modes

SQLite has three `auto_vacuum` modes, controlled by `PRAGMA auto_vacuum`:

**NONE (0)** is the default. Freed pages go to the freelist. The file never shrinks. You can reclaim space manually by running `VACUUM`, which rebuilds the entire database. On a 6.9 GB file, that means writing 6.9 GB of data to a temporary file, then replacing the original. It works, but it locks the database for the duration and requires enough free disk space for the copy.

**FULL (1)** reclaims space after every transaction that frees pages. No freelist accumulation, the file stays compact. The cost is extra write I/O on every delete and update, because SQLite has to move pages around to keep the file contiguous. For write-heavy workloads (like, say, a cache or job queue), this adds measurable overhead to every operation.

**INCREMENTAL (2)** is the middle ground. Freed pages get tracked (not on the freelist, but in a pointer map), and the file shrinks only when you explicitly run `PRAGMA incremental_vacuum(N)`, which reclaims up to N pages. You control when and how much space gets reclaimed.

For Rails applications, INCREMENTAL is the right choice. It avoids the constant overhead of FULL mode, and it gives you a hook to reclaim space on your own schedule, in a background job, during low traffic, whatever makes sense.

## Setting it up in Rails

There's a catch. `auto_vacuum` must be set before the first table is created in a database, or you need to run `VACUUM` to restructure the file. This is because FULL and INCREMENTAL modes use a different internal page format (pointer-map pages) that NONE doesn't have.

In Rails, you set pragmas in `database.yml`:

```yaml
production:
  primary:
    <<: *default
    database: storage/production.sqlite3
    pragmas:
      auto_vacuum: incremental

  cache:
    <<: *default
    database: storage/production_cache.sqlite3
    migrations_paths: db/cache_migrate
    pragmas:
      auto_vacuum: incremental

  queue:
    <<: *default
    database: storage/production_queue.sqlite3
    migrations_paths: db/queue_migrate
    pragmas:
      auto_vacuum: incremental

  cable:
    <<: *default
    database: storage/production_cable.sqlite3
    migrations_paths: db/cable_migrate
    pragmas:
      auto_vacuum: incremental
```

For new databases, that's all you need. Rails will set the pragma before creating any tables, and INCREMENTAL mode is active from the start.

For existing databases, you need to run `VACUUM` once to restructure the file. I did this in a migration:

```ruby
class EnableIncrementalAutoVacuumOnAllDatabases < ActiveRecord::Migration[8.0]
  def up
    # auto_vacuum pragma is already set via database.yml,
    # but existing databases need a VACUUM to restructure
    # the file format for incremental mode.
    execute "VACUUM"
  end

  def down
    # Can't undo a VACUUM, but the pragma change
    # can be reverted in database.yml
  end
end
```

If your database is large, this migration will take a while and lock the database for the duration. For a 6.9 GB file, it took about 45 seconds on my server. Plan accordingly. If you're running Kamal, this will happen during deploy, so your app will be down for that window. For most SQLite databases in Rails apps, we're talking single-digit seconds.

You'll also want a migration for each database that needs it. The cache, queue, and cable databases all get their own migration directories, so create equivalent migrations in each.

## Reclaiming space on a schedule

With INCREMENTAL mode active, freed pages accumulate but the file doesn't shrink until you run `PRAGMA incremental_vacuum`. I set up a recurring job to handle this:

```ruby
class IncrementalVacuumJob < ApplicationJob
  def perform
    # Reclaim up to 1000 pages (~4 MB with default page size)
    ActiveRecord::Base.connection.execute("PRAGMA incremental_vacuum(1000)")
  end
end
```

Scheduled in `config/recurring.yml` for Solid Queue:

```yaml
incremental_vacuum:
  class: IncrementalVacuumJob
  every: 1.hour
```

The `1000` argument means "reclaim up to 1000 free pages." With SQLite's default 4 KB page size, that's roughly 4 MB per run. If there are fewer than 1000 free pages, it reclaims whatever is available. If there are none, it's a no-op.

You can tune this. If your cache churns heavily, bump it up or run it more frequently. If your primary database barely deletes anything, once a day is fine. The point is that you're in control, and the operation is bounded: it won't lock the database for 45 seconds like a full `VACUUM` would.

For the cache and queue databases, you'd run the pragma against those connections specifically:

```ruby
class IncrementalVacuumJob < ApplicationJob
  def perform
    connections = [
      ActiveRecord::Base,
      SolidCache::Record,
      SolidQueue::Record
    ]

    connections.each do |base|
      base.connection.execute("PRAGMA incremental_vacuum(1000)")
    end
  end
end
```

## How to check your databases right now

If you're running SQLite in production with Rails 8, check your current state:

```bash
# SSH into your server (Kamal example)
kamal console

# Check auto_vacuum mode (0 = NONE, 1 = FULL, 2 = INCREMENTAL)
ActiveRecord::Base.connection.execute("PRAGMA auto_vacuum").first["auto_vacuum"]

# Check how much space is reclaimable
result = ActiveRecord::Base.connection.execute(<<~SQL)
  SELECT page_count * page_size AS total_bytes,
         freelist_count * page_size AS free_bytes
  FROM pragma_page_count, pragma_page_size, pragma_freelist_count
SQL
total = result.first["total_bytes"]
free = result.first["free_bytes"]
puts "Total: #{total / 1_048_576} MB, Free: #{free / 1_048_576} MB"
```

If `auto_vacuum` returns 0 and `free_bytes` is large relative to `total_bytes`, you've got a database file that's bigger than it needs to be.

Check all your databases. The primary database might be fine if you're mostly inserting, but the cache database almost certainly has wasted space.

## Which databases care most

**Solid Cache** is the biggest concern. Cache entries are written and expired constantly. Without auto_vacuum, the cache database file will grow to whatever your peak cache size has been and never shrink below that, even if you reduce the cache size or clear it.

**Solid Queue** matters if you process a lot of jobs. Completed jobs get swept, but the space stays allocated. If you had a burst of a hundred thousand jobs last month, that space is still reserved on disk.

**Solid Cable** is usually small, but if you have active WebSocket traffic, it churns too.

**Ahoy or any analytics** that cleans up old data will accumulate dead space proportional to your cleanup cadence. If you keep 90 days of events and delete older ones daily, after a year you've allocated space for a year of events even though you only hold 90 days.

**The primary database** is usually fine, since most Rails apps accumulate records rather than deleting them. But if you have any cleanup jobs or soft-delete sweepers, check it too.

## Why this isn't talked about more

Most people running SQLite in production with Rails are early adopters. The Solid suite landed in Rails 8, and Rails 8 itself is still relatively new. The combination of "SQLite in production" and "tables that churn data" hasn't been widespread long enough for this to become common knowledge.

On top of that, disk space is cheap and the growth is gradual. You don't get an error. Your app doesn't slow down (SQLite reuses free pages efficiently). You just quietly accumulate a database file that's ten or fifty times larger than your actual data. It's the kind of thing you only notice when you're checking disk usage for an unrelated reason, or when your 20 GB VPS runs out of space.

The fix is straightforward once you know about it. Set `auto_vacuum: incremental` in `database.yml`, run `VACUUM` once on existing databases, and schedule `PRAGMA incremental_vacuum` to run periodically. That's it. Your database files will reflect your actual data size instead of your historical peak.
