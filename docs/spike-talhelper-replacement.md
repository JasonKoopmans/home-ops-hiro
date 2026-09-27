# Spike: replacing talhelper

talhelper (`aqua:budimanjojo/talhelper` pinned at `3.1.17` in `.mise.toml`)
shipped its last release and the repo is archived — see
[v3.1.17](https://github.com/budimanjojo/talhelper/releases/tag/v3.1.17).
No further fixes land for new Talos machine-config schema changes, so a stale
talhelper eventually can't express what a newer Talos version needs. This is
a spike, not a migration: it evaluates the two maintainer-recommended
successors and recommends one. Nothing in `talos/` or `.taskfiles/talos/`
changes here.

## What this repo actually depends on

`.taskfiles/talos/Taskfile.yaml` wraps talhelper for five operations:

- `generate-config` → `talhelper genconfig` — renders per-node configs from `talconfig.yaml`
- `apply-node` → `talhelper gencommand apply ... | bash` — wraps `talosctl apply-config`
- `upgrade-node` → `talhelper gencommand upgrade ... | bash` — wraps `talosctl upgrade`
- `upgrade-k8s` → `talhelper gencommand upgrade-k8s ... | bash` — wraps `talosctl upgrade-k8s`
- `reset` → `talhelper gencommand reset ... | bash` — wraps `talosctl reset`

Two features in `talos/talconfig.yaml` matter beyond the basic node list:

1. **Inline Image Factory schematics.** Each node declares
   `customization.systemExtensions.officialExtensions` directly in
   `talconfig.yaml` (see the `&schematic` anchor, ~line 25); talhelper submits
   that to the factory and derives the installer image itself. The comment
   next to it documents why this matters: a hand-copied schematic hash
   previously drifted on `cmp-05` and 404'd against the factory. Any
   replacement needs to keep this generate-from-declaration property, not
   regress to a hand-copied hash.
2. **A SOPS-encrypted secrets bundle**, `talos/talsecret.sops.yaml`, holding
   the cluster's PKI/tokens. talhelper reads it directly; whatever replaces
   it needs to either read this file as-is or have a clean migration path
   for it.

## Candidates

Both were named as maintainer-recommended successors in the talhelper
archival notice.

| | [topf](https://github.com/postfinance/topf) | [talstomize](https://github.com/mirceanton/talstomize) |
|---|---|---|
| Maintainer | PostFinance | community (mirceanton) |
| First release | Dec 2025 | Aug 2026 |
| Latest tag (2026-09-27) | `v0.6.0`, real semver, ~monthly cadence | `v0.1.0-rc.2` — no non-rc release yet |
| Stars | 165 | 32 |
| Config model | single `topf.yaml` + layered patch files (`all/`, `<role>/`, `node/<host>/`) — closest analog to talhelper's model | Kustomize-style bases/overlays, own `config.talstomize.dev/v1alpha1` schema |
| `apply`/`upgrade`/`reset` | native subcommands, talosctl-equivalent flags plus things talhelper never had (drain with PDB fallback, staged upgrades, `--max-parallel`, `--dry-run`) | **no** — `apply`/`diff` only; docs state explicitly it "never runs talosctl upgrade/upgrade-k8s itself" |
| Secrets | `topf secrets` generates **and** stores the bundle, SOPS-encrypts on write automatically, reads an existing `talsecret.sops.yaml` unmodified (just rename to `secrets.yaml`) | reads an externally-generated `talosctl gen secrets` bundle only — doesn't generate/rotate |
| Schematic handling | declare `customization.systemExtensions` in a file, ID computed locally as a deterministic hash (same property talhelper has), `--submit-to-factory` registers new ones — direct drop-in for the `&schematic` block | supported, but not evaluated in depth given the gaps above |
| Migration docs | has a dedicated [`migration-from-talhelper.md`](https://github.com/postfinance/topf/blob/main/docs/migration-from-talhelper.md) with a worked example | none |

Sources checked directly rather than taken from marketing copy: both repos'
release lists via `gh release list`, topf's `docs/commands/{secrets,upgrade,
reset,schematic-ids}.md`, `docs/configuration.md`, `docs/migration-from-
talhelper.md`, and talstomize's README.

## Recommendation: topf

talstomize is seven weeks old, pre-`v0.1.0`, and by its own docs doesn't
cover three of the five talhelper operations this repo uses (`upgrade`,
`upgrade-k8s`, `reset`) — adopting it now would mean keeping `talosctl`
hand-run for exactly the risky operations (node upgrades, resets) where a
wrapper earns its keep. It's worth re-checking once it has upgrade/reset
support and a stable release, not before.

topf is a closer match on every axis that matters here:

- Its `apply` subcommand combines `genconfig` + `apply-config` into one step,
  same as `talhelper gencommand apply | bash` does today.
- Its `upgrade` subcommand is a strict superset of `talhelper gencommand
  upgrade`: proper node drain with a PDB-eviction-failure fallback (talhelper
  just shells out to `talosctl upgrade --drain=<mode>` with no retry logic),
  `--dry-run`, `--max-parallel`, and staged upgrades. This repo's
  `upgrade-node` task comment already warns about draining interacting with
  Telegram alerts — topf's drain handling is more defensive than what's
  there now.
- `kubernetesVersion` in `topf.yaml` mirrors `talenv.yaml`'s field, and the
  docs explicitly recommend keeping `talosctl upgrade-k8s --to <version>`
  as the upgrade path (same command `upgrade-k8s` already shells out to) —
  so that task barely changes.
- Secrets migration is a file rename: `talsecret.sops.yaml` → `secrets.yaml`,
  same directory, same SOPS encryption, no format conversion.
- Schematic handling preserves the exact property the `&schematic` comment
  in `talconfig.yaml` depends on — a declared extension list, a locally
  computed deterministic hash, and `--submit-to-factory` for anything the
  factory hasn't seen. No hand-copied hashes reintroduced.

## What migration would actually touch (not done here)

1. `.mise.toml`: swap `aqua:budimanjojo/talhelper` for topf's install method
   (Homebrew tap, `go install`, or a binary/container release — aqua support
   unconfirmed, check before assuming the same `aqua:` line style works).
2. `talos/talconfig.yaml` → `talos/topf.yaml` + `talos/all/*.yaml` patch
   files, following the field renames in topf's migration guide
   (`ipAddress`→`ip`, `hostname`→`host`, `controlPlane: true`→`role:
   control-plane`, JSON6902 patches rewritten as strategic-merge with
   `$patch: delete`).
3. `talos/talsecret.sops.yaml` → `talos/secrets.yaml` (rename only).
4. `.taskfiles/talos/Taskfile.yaml`: five `talhelper gencommand ... | bash`
   one-liners become `topf apply` / `topf upgrade` / `topf reset`, each with
   its own real flags instead of talhelper's `--extra-flags` passthrough —
   worth deciding deliberately (e.g. `--drain-timeout`, `--max-parallel`)
   rather than copying the current defaults blind.
5. A real dry run against a non-control-plane node (`hiro-cmp-04` is the
   least disruptive target) before trusting it against control-plane nodes
   or `reset`.

## Revisit trigger

Tracked in [revisit-register.md](revisit-register.md). Re-open this once
topf's `kubernetesVersion` field and Talos ≥1.14's `UnattendedInstallConfig`
handling have been confirmed against this cluster's actual Talos version, or
sooner if a Talos release lands that talhelper 3.1.17 can't express.
