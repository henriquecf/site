BSPK is a clienteling platform for top-tier luxury retail brands. Each customer organization gets its own subdomains: `acme.bspk.com`, `globex.bspk.com`, whatever they need. Those domains are stored as a `dns_names` array (citext[]) on the `Company` model in PostgreSQL. Organizations add and remove domains over time. Nothing about this is static.

On Heroku, SSL was invisible. You don't think about certificates. You push code, Heroku handles the rest. When we started migrating to Kamal 2 on EC2, that comfort disappeared fast. We now needed to handle TLS termination ourselves, for a dynamic set of domains that could change any day.

The constraint was clear: we couldn't pre-provision certificates for domains that don't exist yet. And we couldn't manually update configs every time a customer adds a subdomain.

## The options we looked at

### kamal-proxy's built-in SSL

Kamal 2 ships with kamal-proxy, which has Let's Encrypt support via HTTP-01 challenges. For a standard app with one or two domains, it works perfectly. You add `ssl: true` to your deploy config and you're done.

For multi-tenant, it falls short. HTTP-01 requires listing each domain individually. You can't do wildcards. With hundreds of tenant domains that change regularly, you'd need to redeploy kamal-proxy every time a customer adds a subdomain. That's not practical.

### Cloudflare proxy

This is what we used initially. Cloudflare's free tier gives you Universal SSL with wildcard coverage for subdomains. Point your DNS at Cloudflare, enable the proxy, and every `*.bspk.com` subdomain gets a certificate automatically.

It works. We ran it this way for a while. But it comes with tradeoffs. Every request routes through Cloudflare's edge network before reaching your server. That's an extra hop and a dependency on a third party for TLS termination. If Cloudflare has an incident, your app is down regardless of whether your server is healthy. And for custom domains (anything not under `*.bspk.com`), you still need individual handling.

We wanted to own the full request path.

### Caddy on-demand TLS

[Caddy](https://caddyserver.com) has a feature called on-demand TLS. Instead of configuring domains upfront, Caddy issues certificates at the moment a request arrives for a new domain. Before issuing, it calls a validation endpoint you define. If that endpoint returns 200, Caddy gets the cert from Let's Encrypt. If it returns anything else, the request is rejected.

That validation endpoint can be anything. In our case, it's a Rails controller that checks the database.

## How it fits together

The request flow looks like this:

```
Client → :443 Caddy (on-demand TLS) → :8080 kamal-proxy → :3000 Rails
```

Caddy handles all TLS. When a request comes in for a domain Caddy hasn't seen before, it pauses, calls the validation endpoint, and if approved, obtains a cert from Let's Encrypt in real time. The client sees a normal HTTPS response. After the first request, the cert is cached and subsequent requests are fast.

kamal-proxy sits behind Caddy, bound to `127.0.0.1:8080`. It only accepts local connections. It still does its job (routing, health checks, zero-downtime deploys), it just doesn't handle TLS anymore.

The Rails app doesn't know or care about any of this. It receives plain HTTP requests from kamal-proxy and responds normally.

## The domain validation endpoint

This is the core of the solution. When Caddy gets a TLS handshake for an unknown domain, it sends a GET request to the validation endpoint with the domain as a query parameter. The controller is simple:

```ruby
module Internal
  class AllowDomainsController < ActionController::API
    def show
      domain = params[:domain]

      if platform_domain?(domain)
        head :ok
      elsif Company.active.containing_dns_name(domain).exists?
        head :ok
      else
        head :not_found
      end
    end

    private

    def platform_domain?(domain)
      allowed = ENV.fetch("PLATFORM_DOMAINS", "").split(",").map(&:strip)
      allowed.include?(domain)
    end
  end
end
```

Two layers of validation. First, it checks a `PLATFORM_DOMAINS` env var for the platform's own domains (`bspk.com`, `app.bspk.com`, etc.). These are static and don't change. Second, it queries the database: does any active company have this domain in its `dns_names` array?

`Company.active` is a scope that filters out deactivated orgs. `containing_dns_name` does a PostgreSQL array contains check. If neither matches, the controller returns 404 and Caddy rejects the TLS handshake. No cert issued, no resources wasted.

The controller inherits from `ActionController::API` rather than `ApplicationController` because it doesn't need sessions, CSRF protection, or any middleware. It's an internal health-check-style endpoint that only Caddy calls from localhost.

Routes are straightforward:

```ruby
namespace :internal do
  resource :allow_domain, only: :show
end
```

## The Caddy and Kamal configuration

The Caddyfile:

```
{
  on_demand_tls {
    ask http://localhost:3000/internal/allow_domain
    interval 2s
    burst 5
  }
  admin off
}

:80 {
  redir https://{host}{uri} permanent
}

https:// {
  tls {
    on_demand
  }
  reverse_proxy localhost:8080
}
```

The `on_demand_tls` block in the global options defines the validation endpoint. `interval` and `burst` rate-limit how often Caddy will ask for new certificates. The `https://` block is a catch-all that applies on-demand TLS to every incoming HTTPS request and proxies to kamal-proxy.

In `deploy.yml`, Caddy runs as a Kamal accessory:

```yaml
accessories:
  caddy:
    image: caddy:2
    roles:
      - web
    options:
      network: host
    files:
      - config/Caddyfile:/etc/caddy/Caddyfile
    volumes:
      - caddy-data:/data
      - caddy-config:/config

proxy:
  ssl: false
  host: 127.0.0.1
  bind_ips:
    - 127.0.0.1
```

A few things worth noting. `network: host` lets Caddy bind directly to ports 80 and 443 on the host. Named volumes (`caddy-data` and `caddy-config`) persist certificates across container restarts. And kamal-proxy binds to `127.0.0.1` so it only accepts connections from Caddy, not from the internet directly.

The deployment sequence matters. Deploy the Rails app and kamal-proxy first, then boot the Caddy accessory. Caddy needs kamal-proxy to be running before it can proxy requests, and the validation endpoint needs the Rails app to be up.

## Gotchas

### force_ssl breaks the validation endpoint

This one was silent and frustrating. Rails' `force_ssl` middleware redirects all HTTP requests to HTTPS. Caddy calls the validation endpoint over HTTP from localhost. So Rails redirects it to `https://localhost:3000/internal/allow_domain`, which doesn't exist. Caddy gets a redirect instead of a 200, treats it as a failure, and never issues the cert.

No error in Caddy's logs, no error in Rails' logs (redirects are 301s, not errors). Just... no certificates.

The fix is to exclude internal paths from `force_ssl`:

```ruby
config.ssl_options = {
  redirect: {
    exclude: ->(request) { request.path.start_with?("/internal/") }
  }
}
```

### kamal-proxy must bind to localhost

If kamal-proxy listens on `0.0.0.0` (the default), it binds to ports 80 and 443. Caddy also needs those ports. They conflict, and one of them fails to start. The fix is `bind_ips: [127.0.0.1]` in `deploy.yml` so kamal-proxy only listens on the loopback interface and Caddy owns the public-facing ports.

### Rate limiting in the Caddyfile is not optional

Without `interval` and `burst` in the on-demand TLS config, anyone can trigger certificate issuance by sending TLS handshakes for arbitrary domains. Caddy will call your validation endpoint (which returns 404), but the overhead adds up. Worse, if your validation endpoint has a bug or the database is slow, you could end up hitting Let's Encrypt's rate limits. The `interval: 2s, burst: 5` setting means Caddy will only check five new domains every two seconds.

### Certificate persistence

Without named Docker volumes for Caddy's data directory, every container restart means Caddy loses its cached certificates and re-issues them all. Let's Encrypt has a rate limit of 50 certificates per registered domain per week. If you're restarting frequently during initial setup (you will be), you can burn through that limit fast. The `caddy-data:/data` volume in the Kamal accessory config solves this.

## What we ended up with

No Cloudflare dependency. No wildcard certificate management. No manual certificate provisioning. When a new customer org is created and given a subdomain, the next request to that subdomain triggers automatic certificate issuance. When a company is deactivated, the `Company.active` scope excludes them from validation, and their cert simply won't renew when it expires.

The validation logic lives in the same database that manages tenants. That's the part I like most about this setup. There's no separate certificate management system to keep in sync. The source of truth for "which domains are valid" is the same `Company` table that the rest of the application uses. One place to look, one place to change.
