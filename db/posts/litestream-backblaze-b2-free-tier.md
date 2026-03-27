If you're running SQLite in production with Rails 8, there's a good chance you've seen the same recommendation I did: use [Litestream](https://litestream.io/) for continuous WAL replication to [Backblaze B2](https://www.backblaze.com/cloud-storage). Litestream watches your SQLite database, streams write-ahead log segments to object storage, and gives you point-in-time recovery. Backblaze B2 offers 10 GB of free storage and unlimited Class A (upload) transactions. It's the default answer to "how do I back up SQLite in production," and for good reason.

I set it up for [Espirita](https://espirita.club), a multi-tenant Rails 8 app running on a single server with Kamal. Followed the Litestream docs, pointed it at a B2 bucket, deployed. Backups started flowing. Everything looked fine.

Two days later, they silently stopped.

## The free tier has a cap nobody talks about

Backblaze B2's free tier is generous on storage and uploads, but it caps **Class C transactions** at 2,500 per day. Class C means `ListObjectsV2` calls, the S3 API operation that lists objects in a bucket. Litestream uses these to check on its own replicated data: which segments exist, which need compaction, which are old enough to delete.

2,500 sounds like plenty. It isn't.

Litestream's default `sync-interval` is 1 second. Every sync cycle, Litestream uploads new WAL segments (Class A, no cap) but also lists existing segments to decide what to compact or clean up. With a 1-second interval, that's potentially 86,400 ListObjectsV2 calls per day from sync alone. My first config used a 1-second interval because that's what the examples show. I was generating roughly 170,000 Class C transactions per day against a 2,500 cap.

The obvious fix: increase the sync interval.

```yaml
dbs:
  - path: /data/production.sqlite3
    replicas:
      - type: s3
        bucket: my-bucket
        sync-interval: 5m
```

Five-minute sync reduces the upload cycles to 288 per day. For my app, a 5-minute recovery point objective is fine. If I lose the server, I lose at most 5 minutes of data. Crisis averted.

Except it wasn't.

## The second wave: compaction monitors

A few days later, I checked the B2 dashboard and saw Class C transactions still exceeding the cap. Not by as much, but still over. The sync interval was 5 minutes. Where were the extra calls coming from?

Litestream has a compaction system that merges small WAL segments into larger ones. It runs at three configurable levels, and each level has a monitoring loop that lists objects to decide when compaction is needed. The default intervals are 30 seconds, 5 minutes, and 1 hour. That innermost 30-second loop was generating around 2,880 ListObjectsV2 calls per day all by itself, independent of the sync interval.

```yaml
# Widen the compaction intervals
levels:
  - interval: 5m    # default: 30s
  - interval: 1h    # default: 5m
  - interval: 24h   # default: 1h
```

I also disabled validation, which periodically downloads and checksums replicated data (generating even more list and get operations):

```yaml
dbs:
  - path: /data/production.sqlite3
    replicas:
      - type: s3
        bucket: my-bucket
        sync-interval: 5m
        validation-interval: 0s  # disable periodic validation
```

Better. But still not enough.

## The third wave: L0 retention checks

The transaction count dropped but kept creeping above 2,500. I dug into Litestream's source code and found another source of ListObjectsV2 calls that isn't obvious from the documentation: L0 retention checks.

Litestream tracks recently compacted files at "level 0" and periodically checks whether they're old enough to delete. The default check interval is 15 seconds. That's 5,760 ListObjectsV2 calls per day from a single timer, more than double the entire free tier budget.

This one was the real culprit. Even after fixing the sync interval and compaction monitors, L0 retention checks alone would have blown past the cap.

```yaml
l0-retention: 1h
l0-retention-check-interval: 1h  # default: 15s
```

## The death spiral

All of this would be manageable if exceeding the cap just meant degraded backups. It doesn't.

When you hit B2's Class C cap, B2 returns HTTP 403 for every subsequent ListObjectsV2 call. Litestream interprets 403 as a transient error and retries. Without backoff. Every failed check triggers an immediate retry, which also fails with 403, which triggers another retry. The monitoring loops that were generating thousands of calls per day now generate thousands of calls per *minute*, all of them failing.

Your backups aren't just paused. They're stuck in a retry storm that won't clear until the daily transaction counter resets at midnight UTC. Meanwhile, no actual replication is happening because the upload operations depend on the list operations to figure out what needs uploading.

I caught this by SSH-ing into the server and tailing the Litestream logs. Wall-to-wall 403 errors, hundreds per second. No alerting, no graceful degradation. The backup process was running, consuming CPU and network, and accomplishing nothing.

## The config that actually works

After three rounds of fixes across about a week, here's where I landed:

```yaml
# Disable Litestream's built-in retention enforcement.
# Use B2 lifecycle rules to clean up old files instead.
retention:
  enabled: false

# L0 retention: keep compacted files for 1h, check once per hour.
l0-retention: 1h
l0-retention-check-interval: 1h

# Widen compaction intervals to reduce list operations.
levels:
  - interval: 5m
  - interval: 1h
  - interval: 24h

dbs:
  - path: /data/production.sqlite3
    replicas:
      - type: s3
        endpoint: s3.us-east-005.backblazeb2.com
        bucket: my-backup-bucket
        path: litestream/production
        force-path-style: true
        sync-interval: 5m
        validation-interval: 0s
```

The core idea: turn off everything that generates ListObjectsV2 calls on a tight loop. Sync every 5 minutes. Compact on wider intervals. Don't validate. Don't enforce retention from Litestream's side.

That last part, disabling retention, might make you nervous. Without retention enforcement, old WAL segments accumulate in the bucket forever. But B2 has its own lifecycle rules that handle this better. In the B2 dashboard, you can set a lifecycle rule on the bucket to auto-delete files older than N days. This runs on B2's side, costs zero API transactions, and achieves the same outcome without Litestream polling.

## Deploying with Kamal

The full Kamal setup runs Litestream as an accessory container sharing the app's data volume:

```yaml
# config/deploy.yml
accessories:
  litestream:
    image: litestream/litestream:latest
    host: 147.93.13.116
    volumes:
      - "ce_storage:/data"
    files:
      - config/litestream.yml:/etc/litestream.yml
    env:
      secret:
        - LITESTREAM_ACCESS_KEY_ID
        - LITESTREAM_SECRET_ACCESS_KEY
      clear:
        LITESTREAM_B2_REGION: us-east-005
        LITESTREAM_B2_BUCKET: ce-espirita-backups
    cmd: replicate -config /etc/litestream.yml
```

The shared volume (`ce_storage:/data`) is important. The Rails app writes to `/data/production.sqlite3` and Litestream reads from the same path. Both containers mount the same Docker volume, so Litestream sees WAL changes as they happen.

B2 credentials live in Rails encrypted credentials and get extracted in `.kamal/secrets`:

```bash
LITESTREAM_ACCESS_KEY_ID=$(bin/rails credentials:fetch litestream.access_key_id -e production)
LITESTREAM_SECRET_ACCESS_KEY=$(bin/rails credentials:fetch litestream.secret_access_key -e production)
```

This avoids `.env` files or hardcoded secrets in the deploy config. The credentials only exist in the encrypted credentials file and in the running container's environment.

## How to check if you're affected

If you're running Litestream with Backblaze B2, log into the B2 dashboard and check your daily transaction counts under **Caps & Alerts**. B2 breaks down transactions by class. If your Class C count is anywhere near 2,500, you're close to the cap.

You can also tail Litestream's logs and look for 403 errors:

```bash
# With Kamal
kamal accessory logs litestream --since 1h | grep 403

# With Docker directly
docker logs litestream 2>&1 | grep 403
```

If you see any 403s, you've already hit the cap and your backups are in the retry spiral. Apply the config changes and restart Litestream:

```bash
kamal accessory reboot litestream
```

## What I'd tell someone setting this up today

Start with the tuned config, not the defaults. The Litestream documentation is written for general S3-compatible storage, and the defaults assume you're on AWS S3 or another provider without tight transaction caps. B2's free tier is a different environment with different constraints, and the defaults will silently exceed it within hours.

Set up B2 lifecycle rules instead of relying on Litestream's retention. It's one less moving part, zero API overhead, and B2 handles it more reliably than a client-side process polling from your server.

And monitor. The worst part of this failure mode is the silence. Litestream doesn't expose a health endpoint or a Prometheus metric for replication status. If your backups stop, you find out when you need them or when you happen to check the logs. I added a simple cron job that checks the most recent object timestamp in the B2 bucket and alerts if it's older than 15 minutes. That's not a Litestream feature. It's a `curl` against the B2 API. But it's the only thing standing between "my backups work" and "my backups stopped a week ago and I didn't notice."

The SQLite-on-one-server stack is genuinely simpler than running PostgreSQL with managed backups. But "simpler" doesn't mean "nothing can go wrong." It means the failure modes are different, and some of them are quieter than what you're used to.

---

*This is a companion to [SQLite in Production: The Disk Space Trap](/blog/sqlite-auto-vacuum-rails), where I covered another silent SQLite issue in Rails: databases that never shrink.*
