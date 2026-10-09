# Spike: replacing talhelper

> **Status:** acted on. The repo now renders with topf; the migration, its rendering checks and what differed from
> talhelper are in the pull request that moved `talos/` to `topf.yaml`, and `talos/README.md` describes the layout.
> The text below is the original spike and still describes talhelper as the current tool.

talhelper (`aqua:budimanjojo/talhelper` pinned at `3.1.17` in `.mise.toml`)
shipped its last release and the repo is archived — see
[v3.1.17](https://github.com/budimanjojo/talhelper/releases/tag/v3.1.17).
No further fixes land for new Talos machine-config schema changes, so a stale
talhelper eventually can't express what a newer Talos version needs. This is
a spike, not a migration: it evaluates the two maintainer-recommended
successors and recommends one. Nothing in `talos/`, `.taskfiles/talos/`, or
`.taskfiles/bootstrap/` changes here.

## What this repo actually depends on

`.taskfiles/talos/Taskfile.yaml` wraps talhelper for five day-2 operations:

- `generate-config` → `talhelper genconfig` — renders per-node configs from `talconfig.yaml`
- `apply-node` → `talhelper gencommand apply ... | bash` — wraps `talosctl apply-config`
- `upgrade-node` → `talhelper gencommand upgrade ... | bash` — wraps `talosctl upgrade`
- `upgrade-k8s` → `talhelper gencommand upgrade-k8s ... | bash` — wraps `talosctl upgrade-k8s`
- `reset` → `talhelper gencommand reset ... | bash` — wraps `talosctl reset`

`.taskfiles/bootstrap/Taskfile.yaml`'s `talos` task is a second, separate
caller — the from-scratch cluster bootstrap, not a day-2 op:

```yaml
- '[ -f talsecret.sops.yaml ] || talhelper gensecret | sops ... > talsecret.sops.yaml'
- talhelper genconfig
- talhelper gencommand apply --extra-flags="--insecure" | bash
- until talhelper gencommand bootstrap | bash; do sleep 10; done
- until talhelper gencommand kubeconfig --extra-flags="{{.ROOT_DIR}} --force" | bash; do sleep 10; done
```

This is the one that actually generates the secrets bundle in the first
place (`talhelper gensecret`, only run if `talsecret.sops.yaml` doesn't
exist yet) and does the insecure first-apply + etcd bootstrap + kubeconfig
pull against fresh maintenance-mode nodes. Any replacement has to cover this
path too, not just the five day-2 tasks — this is what stands the cluster
back up after a full reset or a from-scratch rebuild.

Two more references exist but aren't live day-2 tooling:

- `.taskfiles/template/Taskfile.yaml`'s `validate-talos-config` (`talhelper
  validate talconfig`) is cluster-template scaffolding from the original
  `onedr0p/cluster-template` bootstrap, in the same category as
  `.github/workflows/e2e.yaml` — which is explicitly gated
  `if: github.repository == 'onedr0p/cluster-template'` and confirmed not to
  run here (already documented in `.github/copilot-instructions.md`). Root
  `task validate` calls `scripts/kubeconform.sh` directly and does not go
  through this template task. Not exercised, not worth migrating.
- `scripts/bootstrap-apps.sh` only checks that the `talhelper` binary is on
  `PATH` (`check_cli ... talhelper ...`); it doesn't invoke config
  generation itself.
- `.taskfiles/template/resources/nodes.schema.cue` mentions "the talconfig
  template" in a comment but is only consumed by the same non-live
  `template:` scaffolding tasks (`cue vet` in `validate-schemas`).

One non-code reference is worth swapping regardless of when migration
actually lands: `docs/feeds/homelab-feeds.opml` subscribed to talhelper's
GitHub releases feed for the weekly feed-watch review. An archived repo's
release feed will never fire again, so that's dead weight — swapped to
topf's releases feed in this PR so the weekly review starts tracking the
tool this doc recommends.

Two features in `talos/talconfig.yaml` matter beyond the basic node list:

1. **Inline Image Factory schematics.** Each node declares
   `customization.systemExtensions.officialExtensions` directly in
   `talconfig.yaml` (see the `&schematic` anchor, ~line 37); talhelper submits
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
| First release | Feb 2026 (`v0.1.0`; repo created Dec 2025) | Aug 2026 |
| Latest tag (2026-09-27) | `v0.6.0`, real semver, ~monthly cadence | `v0.1.0-rc.2` — no non-rc release yet |
| Stars | 165 | 32 |
| Config model | single `topf.yaml` + layered patch files (`all/`, `<role>/`, `node/<host>/`) — closest analog to talhelper's model | Kustomize-style bases/overlays, own `config.talstomize.dev/v1alpha1` schema |
| `apply`/`upgrade`/`reset` | native subcommands, talosctl-equivalent flags plus things talhelper never had (drain with PDB fallback, staged upgrades, `--max-parallel`, `--dry-run`) | **no** — `apply`/`diff` only; docs state explicitly it "never runs talosctl upgrade/upgrade-k8s itself" |
| Secrets | `topf secrets` generates **and** stores the bundle, SOPS-encrypts on write automatically, reads an existing `talsecret.sops.yaml` unmodified — target name has to stay `*.sops.yaml`-suffixed for this repo's own `.sops.yaml` rule to match (see below), not topf's default `secrets.yaml` | reads an externally-generated `talosctl gen secrets` bundle only — doesn't generate/rotate |
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
  `upgrade-node` task carries a comment warning that the *reboot* itself can
  page Telegram via `KubeNodeNotReady`/`Unreachable` — a different risk than
  drain/eviction failure. topf's `--stabilization-duration` (gating uncordon
  on the node actually staying ready post-reboot, not just rebooting) is
  more deliberate about that specific window than talhelper's bare
  `talosctl upgrade --drain=<mode>` call.
- `kubernetesVersion` in `topf.yaml` mirrors `talenv.yaml`'s field, and the
  docs explicitly recommend keeping `talosctl upgrade-k8s --to <version>`
  as the upgrade path (same command `upgrade-k8s` already shells out to) —
  so that task barely changes.
- Secrets migration is a rename, same directory, same SOPS encryption, no
  format conversion — but **not** to topf's own default filename. This
  repo's `.sops.yaml` (line 3) matches encryption targets by
  `path_regex: talos/.*\.sops\.ya?ml` — a bare `secrets.yaml` wouldn't match
  that rule, so any future re-encryption (rotation, `sops updatekeys`)
  wouldn't pick up the age key automatically. topf's `secretsPath` field
  takes any filename, so the fix is `talos/talsecret.sops.yaml` →
  `talos/secrets.sops.yaml` with `secretsPath: secrets.sops.yaml` set in
  `topf.yaml`, keeping the `*.sops.yaml` suffix the creation rule expects.
  `topf secrets` also directly replaces `talhelper gensecret`: it generates
  a bundle when none exists (with a confirmation prompt, skippable via
  `--confirm=false` the same way `bootstrap:talos` would need in CI), stores
  it SOPS-encrypted automatically, and prints it to stdout — no separate
  `sops --encrypt` pipe needed.
- `topf apply` covers the from-scratch bootstrap path natively and then
  some: it detects maintenance-mode nodes itself (no `--insecure` flag to
  remember), has a real `--dry-run` that diffs and exits non-zero on
  pending changes (closer to what "dry-run" should mean than Task's own
  `--dry`, which just echoes commands without evaluating them), and
  `--auto-bootstrap` calls the etcd bootstrap API against the first
  control-plane node with its own 10-minute retry — replacing the
  `until talhelper gencommand bootstrap | bash; do sleep 10; done` polling
  loop. A `topf kubeconfig` command replaces the kubeconfig-fetch line too.
  `bootstrap/Taskfile.yaml`'s `talos` task — five talhelper-wrapped lines
  today — collapses to three: `topf secrets --confirm=false`, `topf apply
  --auto-bootstrap --confirm=false`, `topf kubeconfig > kubeconfig`.
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
3. `talos/talsecret.sops.yaml` → `talos/secrets.sops.yaml` (rename, kept
   `*.sops.yaml`-suffixed — see the SOPS creation-rule note above — not
   topf's default `secrets.yaml`; set `secretsPath: secrets.sops.yaml` in
   `topf.yaml`). The rename touches every hard-coded reference to the old
   filename too: `.taskfiles/bootstrap/Taskfile.yaml` (covered by item 5
   below) and `.github/workflows/e2e.yaml` (not live in this repo, so lower
   priority, but still references the old name).
4. `.taskfiles/talos/Taskfile.yaml`: five `talhelper gencommand ... | bash`
   one-liners become `topf apply` / `topf upgrade` / `topf reset`, each with
   its own real flags instead of talhelper's `--extra-flags` passthrough —
   worth deciding deliberately (e.g. `--drain-timeout`, `--max-parallel`)
   rather than copying the current defaults blind.
5. `.taskfiles/bootstrap/Taskfile.yaml`'s `talos` task: five talhelper lines
   collapse to `topf secrets --confirm=false`, `topf apply --auto-bootstrap
   --confirm=false`, `topf kubeconfig > kubeconfig` — this is the path that
   creates `talsecret.sops.yaml`/`secrets.sops.yaml` in the first place, so it
   needs its own from-scratch test, not just a reuse of an existing bundle.
6. A real dry run against a non-control-plane node (`hiro-cmp-04` is the
   least disruptive target) before trusting it against control-plane nodes
   or `reset`. The bootstrap path (item 5) can't be dry-run against the live
   cluster at all — it only exercises against fresh/maintenance-mode nodes,
   so it needs a scratch VM or a full `reset` first, deliberately scheduled,
   not folded into the day-2 dry run.

## Local testing performed

This isn't a future risk — it's already live. Ran both tools against this
repo's actual `talos/` directory (main checkout, age key + kubeconfig
present, sandbox disabled for LAN/registry access; binaries fetched from
each project's GitHub releases with checksums verified against the
published `checksums.txt` before running):

- **`talhelper genconfig` fails right now**, against the `talenv.yaml`
  already committed on `main` (`talosVersion: v1.13.10`,
  `kubernetesVersion: v1.37.1`):

  ```
  field: "kubernetesVersion"
    * version of Kubernetes 1.37.1 is too new to be used with Talos 1.13.10
  field: "talosVersion"
    * WARNING: "v1.13.10" might not be compatible with this Talhelper version you're using
  failed to parse config file: please fix issues with your config file
  ```

  talhelper 3.1.17's built-in compatibility matrix predates this version
  pair, and since it's archived, no update will ever accept it. `task
  talos:generate-config` fails identically today if run against `main`.

- **`topf render` succeeds on the first attempt** against the same
  `talosVersion`/`kubernetesVersion`, using a hand-translated `topf.yaml` +
  `all/`/`control-plane/`/`node/<host>/` patch set built from the real
  `talconfig.yaml` and all six `patches/global/*.yaml` files (only syntax
  change needed: `$$patch: delete` → `$patch: delete`, talhelper's own
  variable-escaping convention topf doesn't use). Rendered all 5 node
  configs to local files.
- **Schematic hash matches exactly.** topf independently computed
  `c23d16533980fd972f96a79cc22130404615c16de18f43da4a40d801d4fe8d6a` from
  the translated `customization.systemExtensions.officialExtensions` list —
  and `curl https://factory.talos.dev/schematics/<id>` returns **200**,
  meaning it's already registered: the exact hash the currently-running
  installer image uses. This is the specific failure mode the `&schematic`
  comment in `talconfig.yaml` warns about (the `cmp-05` 65-char-ID 404
  incident), and it reproduces byte-for-byte between the two tools.
- **Per-node output is otherwise identical.** Diffing `hiro-cmp-01`'s
  rendered config against `hiro-cmp-02`'s (secret-bearing lines stripped)
  shows only the two fields that should differ — `hardwareAddr` and the
  node's IP address. Install disk, network routes/MTU/VIP, Longhorn node
  labels/annotations, kubelet GC thresholds, sysctls, NTP servers, the
  `machine.files` CRI override, `cluster.network` (pod/svc subnets, CNI
  disabled), cert SANs, and the `UserVolumeConfig` Longhorn disk all came
  through correctly on every node.
- **Caution for whoever runs this next:** a rendered machine config
  contains the cluster's decrypted secrets (etcd/k8s CA keys, join token).
  One verification `grep -A2` incidentally printed the cluster's bootstrap
  token into this session's tool output while checking `podSubnets`/
  `certSANs` — low blast radius alone, but treat rendered output as secret
  material, avoid context-line greps near `token:`/`crt:`/`key:` fields, and
  don't leave rendered files lying around afterward (all scratch files —
  rendered configs, the `secrets.yaml` copy, downloaded tarballs — were
  deleted after this verification).

This was a render-only comparison — no `apply`/`upgrade`/`reset` was run
against any node, and nothing on the live cluster changed.

## Revisit trigger

Superseded: the migration was done (see the status note at the top) and its register entries are gone. One path is
still unexercised against real nodes: `task bootstrap:talos` (from-scratch bootstrap with `topf apply
--auto-bootstrap`) only runs on nodes in maintenance mode. Try it on a scratch node before relying on it.
