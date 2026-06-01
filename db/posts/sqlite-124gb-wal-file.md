A few weeks ago I noticed one of my servers was almost full. Not "getting full," almost full. The kind of full where the next deploy fails and you find out about it at the worst possible time.

This is the fourth time SQLite's defaults have surprised me in production, so I'm starting to recognize the shape of it. The first three were about [disk space and auto_vacuum](/blog/sqlite-auto-vacuum-rails), [Litestream eating Backblaze's free tier](/blog/litestream-backblaze-b2-free-tier), and [replacing all of it with a cron job](/blog/sqlite-backups-the-boring-way). This one is about a write-ahead log file that grew to 124 GB while every safeguard against exactly that was switched on.

The villain, it turned out, was my performance monitoring tool.

## 93% and climbing

The first command I ran was the obvious one:

```
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       197G  175G   15G  93% /
```

15 GB free on a 197 GB disk. This is a single VPS that hosts a handful of my side projects, all deployed with Kamal, each with its own Docker volume for SQLite databases and Active Storage files. [espirita.club](https://espirita.club) is the busiest of them.

My first instinct was wrong, which is worth admitting because it cost me twenty minutes. I assumed it was Docker cruft. Old images, stopped containers, dangling layers. That's the usual suspect when a Kamal host fills up, and pruning is harmless, so I started there:

```
$ docker system df
TYPE          TOTAL   ACTIVE  SIZE     RECLAIMABLE
Images        ...                      ~1.6GB
Containers    ...                      1.597MB
Local Volumes ...     150.8GB          278.5kB (0%)
```

That last line is the tell I glossed over the first time. The Docker volumes held 150 GB, and almost none of it was reclaimable. Pruning images and stopped containers freed a little over a gigabyte, far less than I'd hoped, because the old image tags shared base layers with the running ones. The disk barely moved.

So the space wasn't Docker overhead. It was data inside a volume. I'd written summary notes to myself claiming the big volume was "just Active Storage uploads," which was a guess dressed up as a fact. The app in question doesn't have anywhere near that much user data. So I went into the volume and actually measured:

```
$ du -h --max-depth=1 /var/lib/docker/volumes/ce_storage/_data/ | sort -rh
```

And there it was:

```
124G    production_pulse.sqlite3-wal
16G     production_pulse.sqlite3
248M    production_pulse.sqlite3-shm
```

A 16 GB SQLite database with a **124 GB write-ahead log** sitting next to it. The main database file was timestamped from that morning and hadn't grown. The `-wal` file had been written to seconds before I looked.

`production_pulse.sqlite3` is the database for [rails_pulse](https://rubygems.org/gems/rails_pulse), a self-hosted performance monitoring gem. It tracks request timings, slow queries, and route performance, and it stores all of that in its own SQLite database, separate from the app's primary data. The "16 GB of telemetry" part is its own conversation. The "124 GB write-ahead log" part is the emergency.

## What a WAL is supposed to do

If you've only used Postgres or MySQL, SQLite's write-ahead log is easy to misunderstand, because it looks like a transaction log but behaves like a staging area.

In WAL mode, SQLite doesn't write changes directly into the main database file. Instead, every modified page is appended to a separate `-wal` file. Readers see a consistent view by reading the main file plus whatever newer pages exist in the WAL. Writers append. Nobody blocks anybody, which is the whole point: WAL mode is what makes SQLite usable under concurrent reads and writes, and it's why Rails turns it on by default.

The WAL isn't meant to grow forever. Periodically, SQLite performs a **checkpoint**: it copies the pages accumulated in the `-wal` file back into the main database, then lets that WAL space be reused. By default this happens automatically. After any commit pushes the WAL past 1000 pages (roughly 4 MB with the default page size), SQLite runs a checkpoint on that connection.

There's a catch in that default, and it's the entire story. The automatic checkpoint is a **PASSIVE** checkpoint. A PASSIVE checkpoint copies what it can and never truncates the file. It reclaims the *space inside* the WAL for reuse, but the file on disk stays whatever size it grew to. More importantly, a checkpoint can only copy frames that sit before the oldest active reader. If some connection is holding an old read snapshot, the checkpoint stops at that reader's position and leaves everything after it in place.

So there are two ways a WAL file balloons. Either nothing ever truncates it, or a long-lived reader keeps pinning the checkpoint so it can never catch up to the writes. I had both.

## The checkpoint that did nothing

Before I understood any of that, I tried the thing you'd try: force a checkpoint that truncates. The `TRUNCATE` variant checkpoints everything it can and then shrinks the `-wal` file back to zero bytes. I ran it inside the running container, against the live database:

```
$ docker exec ce-web-... \
    sqlite3 /rails/storage/production_pulse.sqlite3 \
    "PRAGMA wal_checkpoint(TRUNCATE);"
1|32254510|731851
```

That output is three numbers, and they tell you exactly why nothing happened.

`wal_checkpoint` returns `busy | log | checkpointed`. The first column is the busy flag: `1` means the checkpoint could not finish because another connection was in the way. The second is the size of the WAL in pages. The third is how many pages were actually checkpointed.

So: **busy**, a WAL of 32,254,510 pages, of which only 731,851 got moved. Thirty-two million pages at 4 KB each is about 128 GB, which matches the 124 GB on disk. The checkpoint moved a couple percent of it and gave up, because the web container had a live connection holding the pulse database open. The WAL didn't shrink. `df` ticked down by a few gigabytes from the partial flush, from 93% to 90%, and that was it.

This is the part that's genuinely counterintuitive if you come from a server database. In Postgres, you tell the database to do something and it does it. In SQLite, the database is a library running inside your application's processes, and a "checkpoint" is constrained by every other connection those processes are holding. A long-running Rails app with a connection pool open against that pulse database was, by simply existing, preventing the WAL from ever being reclaimed. Forcing a checkpoint from a second connection couldn't override the first one's read position.

## Every safeguard was on, and that was the problem

Here's what makes this one worth writing about rather than just fixing and forgetting.

rails_pulse is not careless about disk. The configuration I had in place was, on paper, exactly what you'd want from a tool that writes a lot of rows:

```ruby
RailsPulse.configure do |config|
  config.archiving_enabled = true
  config.full_retention_period = 2.weeks
  config.max_table_records = {
    rails_pulse_requests: 10_000,
    rails_pulse_operations: 50_000,
    rails_pulse_routes: 1_000,
    rails_pulse_queries: 500
  }
end
```

Two-week retention. Hard caps on row counts per table. A cleanup job running every night and a summary job running every hour. I'd even added an initializer that turned on incremental `auto_vacuum` on the pulse database specifically, with a comment to my future self explaining that SQLite won't reclaim deleted space otherwise. I'd read my own [earlier post](/blog/sqlite-auto-vacuum-rails) and applied its lesson.

None of it took effect, and the reason is the WAL.

Retention works by deleting rows. Row caps work by deleting rows. `auto_vacuum` reclaims pages freed by deletions. But every one of those operations is a write, and in WAL mode a write goes into the `-wal` file first and only lands in the main database at checkpoint time. If the WAL never checkpoints, the deletes never actually shrink the main database, the freed pages auto_vacuum is supposed to reclaim never make it back, and the delete operations themselves pile up as more pages in the WAL. The cleanup job ran every night and, as far as the file on disk was concerned, made things worse each time.

So I had a monitoring tool diligently generating cleanup writes, those writes feeding a WAL that couldn't checkpoint because the app held it open, and the WAL growing without bound until it was eight times the size of the database it was logging. The tool I'd installed to watch for performance problems was the performance problem.

## The fix, and why the order mattered

The naive fix is to delete the giant `-wal` file and move on. Don't do that while the application is running. Deleting a WAL out from under an open SQLite connection can corrupt the database, because the connection still believes those committed pages exist in the WAL and haven't been checkpointed into the main file yet. And on Linux, deleting a file that a process still has open doesn't even free the space. The inode sticks around until the process closes the handle, so you'd get corruption risk and no disk back.

I could have tried to fix it in place: schedule a recurring `TRUNCATE` checkpoint, or recycle the connection pool so no reader stays pinned, or move the pulse data off SQLite entirely. But sitting there at 90% disk, I had to decide whether this tool was earning its place at all, and the honest answer was no. I almost never opened the dashboard. On a single VPS running a few side projects, the operational risk of an unbounded-growth failure mode was worth more attention than the monitoring data was saving me. The right move wasn't to fix the checkpoint. It was to remove the thing.

That made the ordering clean. The only thing holding the WAL open was the running container's connection to the pulse database. So:

1. Remove rails_pulse from the application. The gem, the separate `pulse` database definition in `database.yml`, the engine mount in `routes.rb`, the recurring jobs, the initializer, the schema files.
2. Deploy. Once the new container boots without any rails_pulse code, nothing opens a connection to the pulse database, and nothing holds the WAL.
3. *Then* delete the orphaned files on the host.

Removing the gem touched a fair amount of config but no real logic, since the gem is self-contained. After `bundle install` and a grep to confirm there were no lingering references, I committed it on a branch, opened a PR for my own records, merged, and deployed.

With the new container up and verified, I checked that nothing held the files open before touching them. `lsof` wasn't installed on the host, so I used `fuser`:

```
$ fuser /var/lib/docker/volumes/ce_storage/_data/production_pulse.sqlite3*
$
```

No output means no process. Safe to delete:

```
$ rm -v /var/lib/docker/volumes/ce_storage/_data/production_pulse.sqlite3 \
        /var/lib/docker/volumes/ce_storage/_data/production_pulse.sqlite3-shm \
        /var/lib/docker/volumes/ce_storage/_data/production_pulse.sqlite3-wal
```

And the payoff:

```
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       197G   31G  159G  17%  /
```

From 93% to 17%. Around 144 GB reclaimed, almost all of it from one app's monitoring database. Both apps on the box returned 200 on their health checks, and that was the end of it.

## What I actually think about this

I want to be careful not to turn one incident into a sweeping verdict. rails_pulse is a genuinely nice tool, the failure was a configuration interaction and not a bug, and on a server with proper WAL checkpoint hygiene it would have been fine. If you're running it and reading this, the lesson isn't "rip it out," it's "make sure something truncates that WAL, and watch the file."

But the decision I made for my own setup was to stop running in-app APM on these boxes, and I'd make it again. Here's the reasoning, since that's the part worth taking away.

A performance monitor that lives inside your app and writes to a database on the same disk is, structurally, a second high-churn workload competing with the thing you're trying to observe. On a big setup with a dedicated metrics store, that's fine, that's the whole architecture. On a single VPS running side projects, it means I've doubled my SQLite operational surface to gain dashboards I check once a month. The math doesn't work. The monitoring was costing me more risk than the outages it was supposed to help me catch.

What I lean on instead is deliberately boring. Request logs are already there and already structured. [Solid Errors](https://github.com/fractaledmind/solid_errors) catches the exceptions that actually matter, in a table small enough that it never causes this class of problem. When I want to know why something is slow, I'd rather reach for a one-off query or a flamegraph during an investigation than pay a continuous tax to have the data pre-collected. For an app with a few active users, the slow paths announce themselves. I don't need a constant feed to find them.

There's a broader pattern across all four of these SQLite posts, and it's not "SQLite is fragile." It's that SQLite gives you a database with no operator. Postgres has a process whose entire job is to vacuum, checkpoint, and manage space in the background, tuned by people who think about nothing else. With SQLite in production you've quietly taken that job, and the defaults assume a workload that may not be yours. auto_vacuum is off. Checkpoints are passive and never truncate. A long-lived connection will pin a WAL forever and nothing warns you. Each of these is reasonable in isolation and each one has bitten me once I ran a workload the default didn't anticipate.

The thing I keep relearning is that the failure is always silent until the disk is full. There's no log line that says "your WAL hasn't checkpointed in three weeks." The file just grows, every safeguard you configured quietly feeds it, and the first signal you get is a number on `df` that's too high to ignore. So now `df -h` and the size of every `-wal` file on the box are on the short list of things I glance at before I trust that everything's fine. It's a cheap habit, and it would have turned this from an emergency into a Tuesday.
