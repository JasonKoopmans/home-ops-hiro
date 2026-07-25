# Homelab Goals & Watch Config

> Machine- and human-readable context for the **weekly upgrade/feature review**. The scheduled agent reads this file each run to decide what's *relevant to this homelab* — not just what changed. Edit freely; the review adapts.

## Design themes (relevance filter, priority order)

New capabilities in any watched product are surfaced when they match one of these. Order = priority when trimming.

1. **AI / automation + cross-product integration** — new agent/LLM features, webhooks, MCP Servers, event triggers, and APIs that let the products I run talk to each other (n8n, Home Assistant, Hermes agent as hubs). *← primary interest.*. *The pace of life is increasing, I want increasing abilities in my home to enrich my life and those around me while reducing the time I spend on it.* 
2. **GitOps-ify clickops** — new declarative/API/Container/CRD config for products currently managed by hand, so they can move toward Git-managed like the rest of the cluster. *I want to be able to manage as much of my home technology through automatable and repeatable means. For any of the products that are not managed in my cluster, I've got an interest in what would enabble them to be able to be managed there.  Today, that's largely driven by the need for specialized network configuration (Homeassistant discovery of devices in the home, Omada discovery of network equipment) or hardware configuration (Plex needing to leverage hardware based video encoding)*
3. **Backup / DR resilience** — snapshot, replication, restore, and failover features across storage and apps. *I consider failure of components inevitable, I need to be able to recover quickly and with less effort over time*
4. **Security** - best practice scanning and vulnerability closure.  *I want to be assured that the products I have configured are reasonably safe as I continue to scale in usage*
5. **Building Composite Systems** - Not **just** technology, but the combination of information, process, technology and automation in loops and repeatable virtuous actions.  *I want the things in my homelab to combine with other products in my ecosystem that enrich my life*


## Non-goals

- Not self-hosting an SSO/IdP (Authelia/Authentik/Keycloak) — Cloudflare Access is the auth layer (see runbook-guacamole-cloudflare-access.md) right now
- Not chasing every point release — Renovate handles routine bumps; the review is for judgment calls and new capabilities. 

## Digest design principles

- **Brevity is a hard constraint.** Every item earns its line. No praise, no filler.
- **All notable features, tiered depth.** Nothing notable is dropped, but depth scales with relevance:
  - Theme-matched feature → expanded: what it enables + one **quoted line from the source** + link.
  - Other notable feature → one line.
  - Routine bump / no news → grouped, one line total.
- **Cite the source.** Every review/feature callout quotes the release note or blog post and links it. No unsourced impact claims.
- **Version-delta for in-repo; feature-watch for out-of-repo.** In-repo products get "you're behind, here's the impact" (diff against Git). Out-of-repo products can't be version-diffed — they're **feature-watch only** (new capabilities from blog/release feeds).

## Run mechanics (state, dedup, fetch)

- **State file:** `docs/feeds/feed-watch-state.json`, committed by the routine each run. Shape:
  - `feeds{ <feedUrl>: <last-item-ISO-date> }` — high-water mark per feed; only items newer are surfaced.
  - `inrepo{ <component>: <last-digested-version> }` — so an already-reported delta doesn't repeat until it changes again.
  - `lastRun: <ISO>`.
  On each run: load state → surface only new items / new deltas → write state back. First run (no file) uses a 35-day window.
- **Fetch method:** GitHub `*.atom` + most blogs = plain HTTPS. **Exceptions needing a browser User-Agent:** Pocket (`heypocket.com`, 403 otherwise). No-RSS products (Todoist, Claude) = fetch the "what's new" page and diff text against state.
- **Cadence:** weekly, Saturday — pre-briefs Renovate's Saturday PRs. See "Delivery" below.

## Watched scope

### In-repo (auto-derived from manifests + `.mise.toml`)
41 apps + toolchain. Versions read live from Git each run. Feed list: `docs/feeds/homelab-feeds.opml`. No manual upkeep — new apps are picked up automatically.

### Out-of-repo products (feature-watch — no version diff)

Managed outside this repo but of keen interest. Blog feeds are the primary signal (feature framing lives in posts, not tags). Feed list lives in **`docs/feeds/feature-feeds.opml`** (separate from `homelab-feeds.opml` — releases = version tracking, this = feature-watch). All URLs below verified live 2026-07-25.

| Product | Role | Blog / feature feed | Release / version feed |
|---|---|---|---|
| Home Assistant | Home automation hub | `www.home-assistant.io/atom.xml` ✓ | `github.com/home-assistant/core/releases.atom` ✓ |
| Tailscale | Mesh VPN / access | `tailscale.com/blog/index.xml` ✓ | `github.com/tailscale/tailscale/releases.atom` ✓ |
| Cloudflare (platform) | Tunnel, Access, DNS, edge | `blog.cloudflare.com/rss/` ✓ + `developers.cloudflare.com/changelog/rss.xml` ✓ | — (cloudflared version tracked in `homelab-feeds.opml`) |
| OPNsense | Firewall / router | `opnsense.org/blog/feed/` ✓ | `github.com/opnsense/core/releases.atom` ✓ |
| netboot.xyz | Network boot / provisioning | — | `github.com/netbootxyz/netboot.xyz/releases.atom` ✓ |
| Plex | Media server | `www.plex.tv/blog/feed/` ✓ | no official RSS (blog covers "New on Plex" monthly) |
| Omada (TP-Link) | Network controller / APs | no RSS (TP-Link notes page, manual) | `github.com/mbentley/docker-omada-controller/tags.atom` ✓ (community image proxy for controller version) |

### Personal / SaaS / AI ecosystem (feature-watch)

Consumer/SaaS products — pure feature-watch, no version diff. Where there's no feed, the review **fetches the vendor's "what's new" page during the run** and diffs against saved state. URLs verified live 2026-07-25.

| Product | Role | Feed / method |
|---|---|---|
| Pocket (heypocket.com) | Call / meeting recorder | `heypocket.com/blogs/news.atom` ✓ — **requires a browser User-Agent** (plain fetch returns HTTP 403; Shopify bot-block). |
| Readwise Reader | Read-later / knowledge | `blog.readwise.io/rss/` ✓ (blog covers Reader) |
| Obsidian **(product / ecosystem)** | Notes / PKM platform | `github.com/obsidianmd/obsidian-releases/releases.atom` ✓ (release notes = new app capabilities). Watch the **whole product surface** — core app features, sync/publish, plugin platform APIs — not one install. See "Obsidian: product vs instances" below. |
| Gemini | AI assistant | `blog.google/products/gemini/rss/` ✓ |
| Todoist | Tasks | no RSS → fetch "What's New" page during run |
| Claude (Anthropic) | AI assistant / MCP | no RSS → fetch `anthropic.com/news` + docs release notes during run |
| Apple ecosystem | Devices / OSes | **deferred — ignore for now** (feeds exist: `apple.com/newsroom/rss-feed.rss`, `developer.apple.com/news/releases/rss/releases.rss`; too broad, revisit later) |

> **Obsidian: product vs instances.** Obsidian (`obsidian.md`) is treated as the **overall product/ecosystem** — the interest is its capabilities as a platform (plugins, sync, publish, bases/APIs). *Instances* are individual install methods: e.g. `default/obsidian` in this repo (`linuxserver/obsidian`), plus any desktop/mobile installs. The feature-watch tracks the **product**; the in-repo instance is version-tracked separately in `homelab-feeds.opml`.

### Dev & AI tooling (feature-watch)

Developer + AI tools I work in daily. Theme 1 (AI/automation) and theme 5 (composite systems) heavy. URLs verified live 2026-07-25.

| Product | Feed |
|---|---|
| GitHub | `github.blog/changelog/feed/` ✓ (feature signal) + `github.blog/feed/` ✓ (blog) |
| GitHub Copilot | `github.blog/changelog/label/copilot/feed/` ✓ (Copilot-scoped changelog) |
| VS Code | `code.visualstudio.com/feed.xml` ✓ (monthly release notes) + `github.com/microsoft/vscode/releases.atom` ✓ (versions) |


## Integration map (for theme 1)

Product→product links to watch for enabling features. **Draft below — Jason to confirm/edit.** The review reads each line as "surface new capabilities in either product that make this link easier."

- Home Assistant events and integrations  →  n8n workflow trigger  *(automation hub feeding the workflow engine)*
- n8n  →  Hermes agent / LLM  *(AI-in-the-loop for workflow decisions)*
- Cloudflare Access  →  central auth for `envoy-internal` services  *(current access-mgmt layer; watch new Access app/policy features)*
- Tailscale network mesh  →  connectivity
- Plex / Home Assistant  →  Homepage dashboard widgets  *(surface external product state on the in-cluster dashboard)*
- Proxmox / Talos - Automation of the operating system layer of my stack

## Delivery & follow-up

- **Output:** one GitHub issue per week (Saturday), labeled `weekly-digest`, title `Weekly digest — <date>`.
- **Scope:** inform-only. The digest does **not** open child issues or PRs itself.
- **Actionable format:** every suggestion is written as a self-contained block (what, why, affected files, source link) so it can be lifted into its own issue in one step. Each carries a `Promote →` line with a ready-to-paste issue title/body.
- **Copilot handoff:** to action a suggestion, create a new issue from its block and assign GitHub Copilot (coding agent) to it; Copilot works it in isolation and opens a PR. The weekly digest issue stays the index; child issues are the units of work. *(Verify the repo has Copilot coding agent enabled before relying on this.)*

---
<sub>Read by the weekly review routine. Keep it short — this file is context, not documentation.</sub>
