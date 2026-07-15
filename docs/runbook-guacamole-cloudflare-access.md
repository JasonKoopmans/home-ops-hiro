# Runbook: Guacamole remote access + Cloudflare Access

Covers the dashboard-side setup that lives **outside this repo** for the
`default/guacamole` app: publishing `workspaces.${SECRET_DOMAIN}`
(`workspaces.koopmans.co`) through Cloudflare Access so Michele can reach her
Windows workstation over VNC from any network, in a browser.

Context: the app is a single pod (guacd + Guacamole webapp) with **no database**.
Authentication is HTTP-header auth — Guacamole trusts the
`Cf-Access-Authenticated-User-Email` header that Cloudflare Access injects — and the
single VNC connection lives in a SOPS-encrypted `user-mapping.xml`. See
`kubernetes/apps/default/guacamole/` and `../home-ops-private/docs/remote-access-plan.md`
(Phase 3).

## Order of operations (safety)

The public HTTPRoute is intentionally **commented out** in `helmrelease.yaml`. Do the
Cloudflare Access setup first — an Access application can be created for the hostname
before the origin exists — and enable the route **last**, so the endpoint is never
reachable on the internet without the Access policy in front of it.

1. Configure the Access application + policy (below).
2. Uncomment the `external:` route block in `helmrelease.yaml`, commit, push, let Flux
   reconcile. external-dns publishes the DNS record; the existing cloudflared tunnel
   already routes `*.${SECRET_DOMAIN}` to the external envoy gateway.
3. Test end to end.

## Cloudflare Access setup (Zero Trust dashboard)

`one.dash.cloudflare.com`

1. **Login method** — Zero Trust → Settings → Authentication. One-time PIN (email code)
   is the least-friction for a non-technical user; Google/GitHub also work.
2. **Application** — Access → Applications → Add an application → **Self-hosted**.
   - Name: `Guacamole`
   - Session duration: e.g. `24h`
   - Public hostname: `workspaces` . `koopmans.co`
   - Identity providers: the method(s) from step 1
3. **Policy** — add a policy on that app:
   - Name: `Allow Michele + operator`, Action: `Allow`
   - Include → Emails → Michele's email + the operator's
   - Optional: Require → Multi-factor authentication
   - Policy order matters — first match wins; keep any `Block` rules above a broad
     `Allow`.
4. **Identity header** — nothing to configure. On a request that passes the policy,
   Cloudflare injects `Cf-Access-Authenticated-User-Email` toward the origin (and
   strips any client-supplied copy at the edge). That header is what Guacamole reads.

## ⚠️ Gotcha 1 — the email must match exactly

Header auth authenticates Michele by the email Cloudflare sends. Guacamole then shows
**only** the connections whose `<authorize username="…">` entry in `user-mapping.xml`
matches that value — **character for character** (normally all lowercase).

If it doesn't match, the failure mode is silent and confusing: she authenticates fine
and lands in Guacamole, but sees **zero connections**. This is the single most common
break for this setup.

- The `<authorize username>` in the SOPS `user-mapping.xml` **must equal** the email in
  the Cloudflare Access "Allow" policy.
- Watch for casing and any `+`-suffix / alias differences.
- To confirm what Cloudflare actually sends, check the Access application logs
  (Zero Trust → Logs → Access) or add a temporary echo route.

## ⚠️ Gotcha 2 — header trust has an internal blind spot

Guacamole **blindly trusts** the `Cf-Access-Authenticated-User-Email` header. That is
safe on the **public** path because Cloudflare strips any forged copy at the edge and
re-adds the authenticated one.

It is **not** enforced on the **internal** route (`envoy-internal`, `192.168.25.101`),
which has no Cloudflare Access in front and does **not** strip the header. Anyone who
can reach `.101` on the LAN/tailnet could send a forged
`Cf-Access-Authenticated-User-Email: michele@…` header and be trusted as her — no login.

- For a homelab where `.101` is only reachable over a trusted LAN/tailnet, this is an
  accepted risk. The internal route otherwise falls back to Guacamole's login form
  (use the `user-mapping.xml` username/password) when no header is present.
- To close it if desired: don't ship the internal route; **or** strip `Cf-Access-*`
  headers on the internal envoy listener; **or** drop header auth on the internal path.
- Do **not** expose the internal route (or the raw `guacamole` Service) via any path
  that bypasses Cloudflare — the header trust assumes Cloudflare is the only front door
  on the public side.

## Test from off-network

On Michele's laptop (or a cellular-tethered browser):

1. Browse to `https://workspaces.koopmans.co`.
2. Redirect to Cloudflare Access → authenticate (OTP/SSO + MFA).
3. Land in Guacamole, already signed in as her email.
4. Her one connection (`Michele Workstation`) appears → click → desktop.

If step 4 shows an empty connection list, re-check **Gotcha 1** (email match) first.
