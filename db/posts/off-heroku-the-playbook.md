A couple of weeks ago I wrote about [migrating BSPK off Heroku](/blog/i-migrated-bspk-off-heroku). That post was the narrative version: what it felt like to drive a multi-month infrastructure project without writing much code, what "agentic engineering" looked like in practice. It stayed away from the actual configs and the bugs because the audience was different.

This is the other post. The one for the ops people sitting on a Heroku bill they're tired of paying. What we moved to, why, and the awkward bugs we hit along the way. Less narrative, more playbook.

## What moved, and to what

The shape of the migration:

- Application servers: Heroku dynos → EC2 hosts via Kamal 2
- Provisioning: hand-rolled bootstrap script → Terraform
- Container registry: Heroku registry → ECR
- Postgres: Heroku Postgres → PlanetScale Postgres
- Redis: Heroku Redis → Upstash
- Elasticsearch: Bonsai → Elastic Cloud
- Elixir Phoenix PubSub service: Gigalixir → Kamal alongside the main app
- CDN: Heroku's edge → CloudFront in front of Rails assets
- DNS: managed internally → Route 53 with weighted records for cutover
- Private networking between hosts: nothing → Tailscale
- Secrets: Heroku config vars → 1Password as the source of truth, pulled at deploy
- Postgres maintenance: we couldn't install non-trusted extensions → pg_squeeze for table bloat

AWS was a constraint our CEO requested, not a preference. On Hetzner, Vultr, or almost any cheap VPS provider, the cost reduction would have been larger. We priced it both ways before starting. The 60%+ reduction we landed on is the conservative version of this move.

## Kamal and Terraform as the deployment unit

The new stack runs on EC2 (m7a.large amd64 in production right now), deployed with Kamal 2. Kamal handles the application container, the kamal-proxy in front of it, the SSH-based rollouts, and the accessory containers like Caddy where we use them.

The first version of the AWS bootstrap was a shell script. It worked, but it described the world implicitly: you ran it, you got a host. There was no canonical source of "this is what production looks like." We rewrote it as Terraform later in the project once the shape stabilized. The README in `terraform/` is the two-step cutover playbook now. Anyone with credentials can plan and apply.

One thing that surprised me: Mac ARM Docker builds against an amd64 production target were painfully slow. The fix was repurposing dev2 (a 32GB VPS we already used for development) as Kamal's remote builder. Now builds run on Linux amd64 directly, the cache stays hot between deploys, and CI deploys finish faster than Heroku's git-push pipeline ever did. The Kamal config for it is one block:

```yaml
builder:
  remote: ssh://deploy@dev2.internal
  cache:
    type: registry
    options:
      mode: max
```

The `mode: max` cache option is what makes the cache durable across deploys. The default mode only stores the final layer, which defeats the point.

For registry credentials, we wired `KAMAL_REGISTRY_PASSWORD` to fall back to the GitHub Actions token when running in CI. Locally it pulls from 1Password. Same Kamal config, two environments, no per-environment branching.

## Secrets without vendor lock-in

Heroku's config vars are convenient. They're also a one-way mirror: you can edit them in the dashboard, but there's no canonical source you can diff or audit outside Heroku itself.

We made 1Password that source. Every production secret lives in a single vault. Kamal pulls them at deploy time using `kamal secrets`. The `.kamal/secrets` file looks like a shell script that exports each variable, sourced from 1Password through their CLI:

```bash
DATABASE_URL=$(op read "op://Production/PostgreSQL/url")
SECRET_KEY_BASE=$(op read "op://Production/Rails/secret_key_base")
PLANETSCALE_DATABASE_URL=$(op read "op://Production/PlanetScale/url")
# ... and so on
```

The dev2 builder and the production hosts both have the 1Password CLI installed and authenticated via service accounts. No `.env` files anywhere. The secrets exist as 1Password items, get pulled at deploy, and live in process memory.

This setup bit us once. `ENCRYPTION_SERVICE_SALT` is a multi-character value that includes characters the shell wants to interpret. Kamal's secret pipeline double-escaped it on the way through, and the running app crashed trying to decrypt a value it had written itself. The fix was wrapping the secret in single quotes inside `.kamal/secrets` so the shell didn't re-interpret the escape sequences. Obvious in retrospect. Not obvious when half the requests are 500s and the other half are fine because they don't hit any encrypted attributes.

## The encrypted attributes hazard

This was the bug I spent the most time on, and it's the one most people doing a Rails-version-plus-host swap will hit.

Rails encrypted attributes derive their key from a digest of the master key plus a salt. Old rows in our database were written with a SHA1-derived digest. The Rails version we were about to ship in production defaulted to SHA256. If I flipped the setting, every existing encrypted value would have become unreadable. If I left it on SHA1, the app would log deprecation warnings and break in a future Rails version.

The fix is a small dance: read with fallback, write with the new digest. On decrypt, try SHA256 first, fall back to SHA1 if that fails, and re-encrypt the value with SHA256 the next time the record gets saved. Existing data heals itself as records get touched. New writes are always SHA256. Nothing breaks at the cutover, and over time the SHA1 footprint shrinks toward zero.

I'm not pasting the exact config because Rails encryption internals are version-specific and the code that's correct as I write this might not be correct when you read this. The pattern is what matters: read with fallback, write with the new digest, let activity drain the legacy values. Invisible if you do it right. Catastrophic if you don't.

## TLS for hundreds of tenant domains

BSPK is multi-tenant. Each customer gets one or more subdomains under our platform domain, plus the option of custom domains pointed at us. On Heroku, ACM and the platform's edge handled TLS invisibly. On EC2, we owned it.

I [wrote up the Caddy on-demand TLS setup](/blog/multi-tenant-ssl-caddy-kamal) when I first built it. Caddy sits in front of kamal-proxy, issues certificates per-domain on the first HTTPS request, and validates each domain against a Rails endpoint that checks the database. It's been running since early in the migration.

The bug worth mentioning that didn't make it into the original Caddy post: a Caddy boot loop on the new EC2 host during a dry-run cutover. The proxy crashed on startup, restarted, crashed again. Logs said `failed to load TLS config` and nothing else useful. The TLS block in the Caddyfile was deriving from a `{$TLS_ENABLED}` env var that wasn't reaching the accessory because Kamal's env block didn't include it. Either passing the variable through or hardcoding `tls_enabled true` would have worked. Hardcoding was simpler and that's what we shipped. Boot loop gone in five minutes.

## The managed services

Application data moved to managed services we don't operate. I'm going to write a separate, deeper post about Postgres → PlanetScale because that piece has its own decisions worth unpacking. The short version here:

**Postgres → PlanetScale.** We kept the Postgres dialect, didn't switch to MySQL on Vitess. The cutover was a config flip thanks to a small change in how Rails picks the database URL: prefer `PLANETSCALE_DATABASE_URL` if present, fall back to `DATABASE_URL` otherwise. We could deploy the new wiring well before the actual data cutover and verify both code paths.

The piece I want to call out, because it's the biggest operational change of the whole migration, is the replica architecture. PlanetScale fronts the primary with replicas, and most schema operations route through the replicas without locking the primary in a way that causes user-visible downtime. On Heroku Postgres, a long-running `ALTER TABLE` on a hot table was the kind of thing you scheduled for a Sunday at 3 AM with a maintenance window. On PlanetScale, most of those operations run live. We've shipped column additions, index builds, and constraint changes during business hours without anybody noticing. That changes how we think about schema work entirely. The old "save it for the next maintenance window" instinct stops applying, and the bottleneck moves from "when can we afford the downtime" to "is this change actually safe."

**Redis → Upstash.** Boring in a good way. One URL change, Sidekiq picked it up, our cache and queue moved over.

**Elasticsearch → Elastic Cloud.** I had help on this one from a coworker who knows ES better than I do. Index aliases made the cutover painless: replicate into the new cluster, swap the alias, the app doesn't notice.

The pattern across all three: keep the connection string indirection, set up the new destination, replicate or seed, then flip the env var. The app code doesn't change.

## The Elixir service came along

We have a small Phoenix app that runs PubSub between front-end clients and the Rails monolith. It used to live on Gigalixir, which is a fine Heroku-shaped host for Elixir. It now lives on the same EC2 fleet as the main app, deployed with Kamal as its own destination.

This was a smaller move than the Rails migration but worth mentioning because it's exactly the same pattern. The Elixir release is a Docker image. Kamal pushes it to ECR, pulls it on the hosts, swaps containers behind kamal-proxy. The Phoenix endpoint reads its database and Redis URLs from the same 1Password-backed secrets file. Consolidating two deployment pipelines into one is its own form of cost reduction.

## Cutover day

The actual cutover was anticlimactic, which was the goal.

Route 53 has weighted records: you can point an A or CNAME at multiple destinations and split traffic by weight. We added the new EC2 elastic IPs to the same record names that pointed at Heroku, with weight 0 to start. The new infrastructure was live, the app was deployed, the database was replicating, but no production traffic was hitting it.

Then we ramped weights. 1%, then 10%, then 50%, then 100%. At each step we watched dashboards, error rates, and a smoke test endpoint that exercises the critical paths. If something went wrong, dropping the weight back to 0 reverted the traffic to Heroku within the DNS TTL.

CI runs that same smoke test on every deploy now. It hits a handful of endpoints across the major surfaces (auth, client search, the Elasticsearch-backed shopper finder, the AI assistant tools, the Stripe webhook handler) and asserts on response codes and a couple of expected body shapes. If any of them fail, the deploy is marked failed even if the rollout itself succeeded.

I cut DNS to 100% on the EC2 fleet on a weekday afternoon. The Heroku side stayed warm for another day in case we needed it. We didn't.

## What we got that we didn't have on Heroku

The migration was framed as a cost reduction, and it was. The operational gains are what I notice day to day.

`pg_squeeze` runs in the database itself and reclaims bloat from heavily-updated tables on a schedule. Heroku Postgres didn't allow non-trusted extensions, so we had no way to do this in place. We had tables that had grown well past their actual size because of long-running update patterns. pg_squeeze undid that. It also failed to bootstrap initially on a malformed schedule literal, and the fix was a one-character correction. I would not have caught that without a real Postgres shell.

We had `pghero` before the migration and it came along to the new stack. What changed is that I trust the slow-query list more now. On Heroku Postgres, the long tail of slow queries was partly a function of shared-host noisy neighbors and a buffer cache we didn't control. On PlanetScale, the slow-query list is closer to "queries that are actually slow because the SQL is bad," which is the version of that signal I want.

CloudWatch holds 30 days of application and access logs with searchable retention. We had less of both on Heroku. I rarely need to search logs, but when I do, it's there.

Deploys are faster. Heroku's git-push pipeline took two to four minutes per deploy depending on slug compilation. Kamal with the dev2 remote builder and registry cache pulls layers in seconds. Deploys are now bound by the rolling restart, not the build.

And the box is visible. Sometimes the right debugging tool is `kamal console`, sometimes it's `ssh` and `htop`. Heroku didn't let us do either.

## What's still in flight

The PlanetScale read replica goes in this week. We sized the primary for write-plus-read load and want to push the read traffic to a replica so the primary can scale further on write throughput alone.

I want to move more runtime config out of secrets and into the database where it can be tenant-scoped. Most of what's in `.kamal/secrets` belongs there. Some of it (feature flags, rate limit defaults) doesn't belong as a platform-wide environment variable in the first place.

And the team angle is unsolved. I drove this migration mostly solo because I was the one with the right Claude Code setup and the most context on the stack. That's not a great long-term equilibrium. The next move is documenting our Kamal and Terraform conventions clearly enough that someone else on the team can drive the next change of this size.

The migration itself is done. The next round of "things we couldn't do on Heroku" is just starting.
