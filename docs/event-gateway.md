# Event gateway (phone and flows to the cluster, by pull)

> **Status:** the generic gateway was rolled out on 2026-10-23, replacing the first single-purpose `health-inbox` Worker (the
> phone Shortcut was cut over to it); the work-calendar mirror ([lifeos-calendar](lifeos-calendar.md)) is the second producer.
> Everything outside the cluster lives in a private repository, `JasonKoopmans/event-gateway` (its
> `docs/contract.md` is the producer contract). This repository holds no gateway manifests; this page keeps the shape, the
> reasons for it and the Cloudflare limits it was designed around.

```
iPhone Shortcut / Power Automate
   -> Cloudflare Worker on workers.dev (owner's personal Cloudflare account)
   -> Cloudflare Queue, HTTP pull consumer
   -> n8n schedule workflow (every 10 minutes) pulls and acks
   -> inside the cluster (health: the track-metric webhook into raw.health_metrics; calendar: the ingest statement)
```

The gateway repository holds the Worker routes, per-producer tokens, a CloudEvents envelope the gateway wraps around every
payload, tests, a mise dev container, CI, a deploy workflow gated on the repo variable `DEPLOY_ENABLED`, an idempotent
`provision.sh`, and the pull-side JSON shapes. The n8n puller workflows live in n8n's own database, outside Git
([n8n](n8n.md)).

## Why it exists, and why it pulls

- **Why a Worker at all:** the work iPhone's managed DNS blocks the owner's whole domain, `/healthz` included, while `workers.dev`
  resolves. Anything the phone must reach cannot sit on the cluster's own hostnames.
- **Why the cluster pulls (do not retry push):** a Worker `fetch()` to a hostname on the cluster's proxied tunnel route returned
  **530 / error 1016 inside Cloudflare**, and no request ever reached Envoy. A Worker cannot call the tunnel hostname. With the
  cluster pulling outbound there is no inbound hop to fail.

## Cloudflare Queues facts the design depends on

Read from the vendor docs on 2026-10-02; re-read them before designing anything new on this path, since limits change.

- **Workers Free:** 10,000 operations a day; **3 operations per message** (write, read, delete) per 64 KB; 128 KB maximum message.
- **Retention on Free is fixed at 24 hours** (paid is configurable up to 14 days). A cluster or n8n outage longer than a day
  silently drops messages. The calendar design accepts this because the next snapshot supersedes lost ones; the health inbox
  has no such cover.
- **Several HTTP pullers on one queue compete**: each message goes to one puller. One queue per subscriber or type, and fan-out
  means the gateway publishes to N queues.
- **A pull consumer needs `contentType: "json"` on send.** The default (v8) encoding is unreadable over HTTP pull.
- A Worker consumer and a pull consumer cannot coexist on one queue.
- On Free the dead-letter queue is probably 24 hours as well, so the pullers **park poison messages in Postgres** (a reject table
  with no payload text) instead of relying on a DLQ.

## Findings that carry over to the calendar work

The Outlook connector behaviour, the redaction rules and the warehouse contract are in [lifeos-calendar](lifeos-calendar.md); the
gateway-relevant parts are the 24-hour retention above, the 3-hour staleness watchdog in the apply workflow, and the rule that a
poison message is parked once it has been delivered more than five times, so it cannot loop until retention drops it.

Calendar data is employer data: tenant checks (the Power Automate HTTP action tier, DLP, whether copying calendar data is allowed)
come before any build, not after.
