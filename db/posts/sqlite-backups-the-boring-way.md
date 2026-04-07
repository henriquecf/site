A month ago I wrote about [tuning Litestream to stay within Backblaze B2's free tier](/blog/litestream-backblaze-b2-free-tier). The post ended with a config that worked: wider sync intervals, disabled retention, B2 lifecycle rules handling cleanup. I shipped it, monitored it for a few days, and called it done.

Three weeks later I ripped the whole thing out and replaced it with a cron job.

## Why Litestream was overkill

Litestream is built for continuous WAL replication. It watches your SQLite database, streams every write-ahead log segment to object storage, and gives you point-in-time recovery. If your server dies at 2:47 PM, you can restore to 2:46 PM. For applications where that matters, it's excellent.

My application is [espirita.club](https://espirita.club), a platform for spiritist organizations. It runs on a single server. If the server dies, I lose whatever happened since the last backup. The question is: how much is acceptable to lose?

For a personal SaaS with a few active organizations, the answer turned out to be "a day." Nobody is making irreversible financial transactions. The content is event schedules, blog posts, membership records. If I lost 24 hours of data, I could recover most of it from the organizations themselves. Point-in-time recovery to the minute is solving a problem I don't have.

Once I accepted that, the complexity of Litestream stopped making sense. Even after the tuning described in my [previous post](/blog/litestream-backblaze-b2-free-tier), I had a Docker sidecar container running continuously, watching a Docker volume, uploading WAL segments to B2, and silently failing whenever B2's transaction limits got weird. Three rounds of config fixes over a month, each one disabling another background monitoring loop that was burning through B2's Class C transaction cap. The system worked, but it required understanding Litestream's internals to keep it working.

The Litestream documentation is great, but it's written for a general S3-compatible storage backend. Backblaze B2's free tier has constraints that the defaults don't account for. Every time I thought I'd found the last hidden source of API calls, another one popped up. L0 retention checks, compaction monitors, validation loops. Each one was individually reasonable and collectively over budget.

## The replacement: two shell scripts and a cron job

I wrote two scripts. One backs up databases, the other backs up Active Storage files.

The database script uses `VACUUM INTO` to create a clean copy of each SQLite file, then `rclone sync` to upload everything to B2:

```bash
#!/bin/bash
set -euo pipefail

STORAGE_DIR="/var/lib/docker/volumes/ce_storage/_data"
BACKUP_DIR="/tmp/ce-db-backups"
B2_BUCKET="ce-espirita-backups"

DATABASES=(
  "production.sqlite3"
  "production_errors.sqlite3"
  "production_pulse.sqlite3"
)

mkdir -p "$BACKUP_DIR"

for db in "${DATABASES[@]}"; do
  src="$STORAGE_DIR/$db"
  dest="$BACKUP_DIR/$db"

  if [ ! -f "$src" ]; then
    echo "$(date -Iseconds) SKIP $db (not found)"
    continue
  fi

  echo "$(date -Iseconds) Backing up $db..."
  sqlite3 "$src" "VACUUM INTO '$dest';"
  echo "$(date -Iseconds) OK $db ($(du -h "$dest" | cut -f1))"
done

echo "$(date -Iseconds) Uploading to b2:$B2_BUCKET/databases/..."
rclone sync "$BACKUP_DIR/" "b2:$B2_BUCKET/databases/" --quiet
rm -rf "$BACKUP_DIR"
echo "$(date -Iseconds) Done."
```

The storage script is even simpler: one `rclone sync` of the Docker volume, excluding SQLite files (those are handled by the other script):

```bash
#!/bin/bash
set -euo pipefail

STORAGE_DIR="/var/lib/docker/volumes/ce_storage/_data"

echo "$(date -Iseconds) Syncing Active Storage files..."
rclone sync "$STORAGE_DIR/" "b2:ce-espirita-backups/files/" \
  --exclude "*.sqlite3*" \
  --quiet
echo "$(date -Iseconds) Done."
```

Two cron entries on the host:

```
0 3 * * *  /usr/local/bin/backup-databases >> /var/log/backup-databases.log 2>&1
30 3 * * * /usr/local/bin/backup-storage >> /var/log/backup-storage.log 2>&1
```

That's it. The scripts run once a day on the host, outside Docker entirely, and upload to the same B2 bucket Litestream was using. No Docker sidecar, no Kamal accessory, no WAL watching, no transaction budgets.

One thing worth noting: the scripts run on the host, not inside Docker. They access the SQLite files via the Docker volume's filesystem path (`/var/lib/docker/volumes/ce_storage/_data/`). This means they don't depend on the app container being up, they don't need to mount shared volumes, and they work even if the app is in the middle of a deploy. It also means `sqlite3` and `rclone` need to be installed on the host, not in the Docker image.

I deliberately skip the cache, queue, and cable databases. They're ephemeral by design. If I lose Solid Cache entries, the cache warms up on its own. If I lose Solid Queue's completed job history, nothing depends on it. The cable database is transient WebSocket state. Only the primary database (user data), Solid Errors (production error history), and Rails Pulse (monitoring data) are worth backing up.

## The `.backup` trap

My first version of the script used SQLite's `.backup` command instead of `VACUUM INTO`. It worked on the primary database but failed immediately on the Pulse database:

```
Error: database is locked
```

`.backup` needs an exclusive lock on the source database. If the Rails app has an open connection (which it always does), `.backup` can't acquire the lock and fails. The primary database happened to have no active writes at 3 AM, so it worked. The Pulse database, which Rails writes to on every request for monitoring, was always busy. The SQLite docs mention the locking requirement, but it's easy to miss when you're writing a quick backup script and testing it against a development database with no concurrent connections.

`VACUUM INTO` works differently. It reads the database page by page and writes a fresh, compacted copy to the destination path. It doesn't need an exclusive lock on the source. The running application can keep reading and writing while the backup runs. The resulting file is also smaller than the original because `VACUUM INTO` reclaims free pages, similar to running a full `VACUUM` but without modifying the source database. It was added in SQLite 3.27.0 (2019), so any reasonably modern system has it.

I hit this bug and fixed it within minutes of deploying the backup scripts. Litestream doesn't have this problem because it reads the WAL file directly, never needing to lock the main database. When you roll your own backups, you have to know about the locking model. The good news is that `VACUUM INTO` is a strictly better option for online backups: it works on busy databases, it compacts the output, and it produces a standalone file that doesn't depend on a WAL for consistency.

## What I lost

Real talk: daily backups are worse than continuous replication in one specific way. If the server dies at 2 AM, I lose almost 24 hours of data. With Litestream, I'd lose at most 5 minutes (my tuned sync interval).

For my use case, that's an acceptable tradeoff. But I want to be explicit about it. If you're running an e-commerce checkout, a financial ledger, or anything where losing a day of data would be catastrophic, daily cron backups are not the answer. Litestream, or a real database with streaming replication, is what you need.

The tradeoff I made is: simpler operations in exchange for a wider recovery window. For a platform where the worst case is re-entering some event schedules, that math works out.

Restore is also simpler than with Litestream. With Litestream, restoring means downloading the base snapshot and replaying WAL segments to a specific point in time. You need Litestream installed, you need the config file, and you need to understand the generation/index structure in the bucket. With the cron approach, restoring is one `rclone copy` command:

```bash
rclone copy b2:ce-espirita-backups/databases/production.sqlite3 /tmp/restore/
```

The file you get back is a complete, consistent SQLite database. No WAL replay, no tooling required beyond `rclone` or even just the B2 web console.

## What I gained

The biggest win is observability. The cron job either runs and uploads, or it fails and I see it in the log. There's a log file with timestamps, one entry per database, one entry per upload. If something breaks, I know exactly when and which step failed. Litestream's failure mode was the opposite: it kept running, kept retrying, kept consuming resources, and the only way to know backups were broken was to check the B2 dashboard or tail the container logs looking for 403s.

The B2 cost management disappeared entirely. `rclone sync` uploads changed files once per day. That's a handful of Class A (upload) transactions and maybe one or two Class C (list) transactions to diff the remote state. Compare that to Litestream's continuous monitoring, which was generating thousands of Class C transactions daily even with the tuned config. I no longer think about B2's daily transaction cap at all.

The deployment got simpler too. Litestream ran as a Kamal accessory, a separate Docker container sharing the app's data volume. That meant the Litestream container, its config file, its environment variables, and its volume mount were all coupled to the app's `deploy.yml`. Removing it cleaned up the deploy config, removed two secrets from `.kamal/secrets`, and eliminated a whole category of "did the accessory come up after deploy" debugging. The backup scripts live on the host, installed once via `scp`, and have no relationship with the app's container lifecycle.

## From blog post to Rails PR

The Litestream post was the second in what turned into a series about running SQLite in production. The first was about [auto_vacuum](/blog/sqlite-auto-vacuum-rails): SQLite's default is to never shrink database files, and if you're running Solid Cache or Solid Queue, your disk fills up silently.

That auto_vacuum post got more traction than I expected. The post hit the front page of a few aggregators and the feedback was consistent: people were surprised this wasn't already a Rails default. Someone suggested I open a PR to make it one.

The idea stuck with me. Every Rails developer who deploys SQLite in production will eventually discover that their database files never shrink. They'll google it, find the `auto_vacuum` pragma, add it to `database.yml`, run a one-time `VACUUM`, and move on. That's a well-documented path now. But it shouldn't be a path at all. If the framework knows you're using SQLite, it should set a sensible default.

So I cloned the Rails repo and [opened a PR](https://github.com/rails/rails/pull/57076).

## What the PR changes

Two things.

First, new SQLite databases created by Rails get `auto_vacuum = incremental` set automatically. This has to happen at database creation time because `auto_vacuum` requires a specific internal page format (pointer-map pages) that can only be set on an empty database. By the time `configure_connection` runs and applies your `database.yml` pragmas, the database file already exists and it's too late.

My first approach was to add `auto_vacuum` to the `DEFAULT_PRAGMAS` constant that Rails already uses for other SQLite settings like `journal_mode` and `journal_size_limit`. That didn't work. `DEFAULT_PRAGMAS` are applied in `configure_connection`, which runs after the database file is created. By that point, `auto_vacuum` can't be changed without a full `VACUUM`. The pragma has to be set on the raw connection before any tables exist.

The implementation hooks into `new_client`, the method that creates the raw `SQLite3::Database` instance. If the database file doesn't exist yet (meaning Rails is about to create it), it sets `auto_vacuum = :incremental` before anything else happens. If you explicitly configure a different `auto_vacuum` value in `database.yml`, your setting wins.

```ruby
def new_client(config)
  database = config[:database].to_s
  new_database = !database.include?(":memory:") && !File.exist?(database)
  db = ::SQLite3::Database.new(database, config)
  if new_database
    pragmas = config[:pragmas] || {}
    db.auto_vacuum = pragmas[:auto_vacuum] || pragmas["auto_vacuum"] || :incremental
  end
  db
end
```

Existing databases are unaffected. If you already have a production SQLite database with `auto_vacuum = none`, this change doesn't touch it. You'd still need to run `VACUUM` once to restructure the file, as described in the [original post](/blog/sqlite-auto-vacuum-rails).

Second, a new `db:maintenance:vacuum` rake task. It runs `PRAGMA incremental_vacuum(1000)` (reclaiming about 4 MB of free pages) and `PRAGMA wal_checkpoint(TRUNCATE)` (resetting the WAL file) on every SQLite database in your configuration. For multi-database apps, it generates per-database variants too (`db:maintenance:vacuum:cache`, etc.).

The task is designed to be scheduled hourly via Solid Queue:

```yaml
# config/recurring.yml
maintenance_vacuum:
  class: MaintenanceVacuumJob
  every: 1.hour
```

Or run manually after a large data deletion.

## The bugs I found along the way

Contributing to Rails means running the full ActiveRecord test suite, not just your own app's tests. That surfaced three issues I never would have found otherwise.

The first was simple: an existing test asserted `auto_vacuum = 0` for in-memory databases. That was correct (in-memory databases can't use auto_vacuum), but the assertion was checking the wrong value after my change. Easy fix.

The second was more interesting. Setting `auto_vacuum` is a write operation internally, and it crashed on readonly database connections:

```
ActiveRecord::StatementInvalid: SQLite3::ReadOnlyException:
  attempt to write a readonly database
```

Rails supports readonly SQLite connections via the `readonly: true` option in `database.yml`. My code was trying to set `auto_vacuum` on every new connection, including readonly ones. The fix was checking `@raw_connection.readonly?` before setting any write-only pragmas. I hadn't considered readonly connections at all because I don't use them in my app.

The third was about test isolation. `auto_vacuum` is a persistent property of a database file. It gets set when the database is created and stays forever. The Rails test suite reuses database files between test runs, so databases created before my change still had `auto_vacuum = none`. Tests asserting the new default kept seeing the old value. The fix was straightforward: use fresh temp database files for each test that checks the default. But finding it required understanding how `auto_vacuum` persists, which is the same "you have to know how SQLite works internally" problem that led me to write the original blog post.

## The pattern

I keep finding the same pattern with SQLite in production on Rails. The default configuration makes reasonable assumptions that fall apart under specific workloads. The fix is usually a pragma change or a small operational script. And the information lives in SQLite documentation that most Rails developers never read, because they came from PostgreSQL where the database handles vacuuming, WAL management, and space reclamation internally.

Rails 8 made SQLite a first-class production option, but the ecosystem around it is still catching up. The Solid suite handles the application-level concerns well. The operational concerns, backups, disk management, monitoring, are still on you.

The auto_vacuum default change would eliminate one of these for every new SQLite database going forward. The Litestream-to-cron migration eliminated another kind of complexity for my specific situation. Neither is universally correct. Both made my production setup simpler and more predictable.

The PR is still open as of this writing. If it lands, future Rails developers using SQLite won't have to discover the disk space trap on their own. If it doesn't, at least the blog post is there.

---

*This is the third in an informal series about SQLite in production with Rails. The first covered [the disk space trap](/blog/sqlite-auto-vacuum-rails), the second covered [Litestream and Backblaze B2's free tier](/blog/litestream-backblaze-b2-free-tier).*
