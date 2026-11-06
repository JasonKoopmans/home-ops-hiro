# Talos (`talos/`)

> Area rules for `talos/`. Repo-wide rules are in `.github/copilot-instructions.md`; layout and commands are in `talos/README.md`.

- Talos machine configuration lives in `talos/`, rendered by [topf](https://github.com/postfinance/topf) (it replaced the archived talhelper). `talos/topf.yaml` lists the nodes and versions; patch files in `talos/all/` and `talos/control-plane/` (applied in filename order, `.tpl` files are Go templates) are merged over what topf generates. The layout and its conventions are in `talos/README.md`.
- **Do not modify Talos configs** unless the issue explicitly asks for infrastructure-level changes. Most application-level work happens only in `kubernetes/`.
- `talosVersion` and `kubernetesVersion` in `talos/topf.yaml` must be a compatible pair, and they are what `task talos:upgrade-node` and `task talos:upgrade-k8s` act on, so Git ahead of the nodes is an upgrade waiting to happen. Do not bump them as a side effect.
- Renovate tracks `talosVersion` from the GitHub releases of `siderolabs/talos` (the `ghcr.io/siderolabs/installer` image stopped at 1.13, so it cannot see 1.14 or later) and `kubernetesVersion` from the `ghcr.io/siderolabs/kubelet` image. Both PRs are merged by hand, then rolled with `task talos:upgrade-node` and `task talos:upgrade-k8s`.
- **`talosVersion` is also the machine-config version contract** topf renders for. At 1.14 that is the full multi-document format (`KubeAPIServerConfig`, `KubeletConfig`, `KubeNodeConfig`, `KubeCoreDNSConfig`, `UnattendedInstallConfig`, `ResolverConfig`, …), and Talos rejects a config that sets the same thing in both v1alpha1 and a document. Settings the documents own go in documents; only etcd, `machine.certSANs`, `sysctls`, `files` and `time` are still v1alpha1. `talosctl upgrade` does not regenerate config, so a version bump is safe to roll, but `generate-config`, `apply-node` and bootstrapping a new node all use the new contract.
- topf emits every 1.14 default, including ones this cluster has not chosen, and omitting a document does not remove it. They are deleted explicitly with `$patch: delete`: Flannel (`KubeFlannelCNIConfig`, Cilium is the CNI) and workload isolation (`SecurityProfileConfig`, #760) in `talos/all/10-disabled-defaults.yaml`, the PodSecurity admission document in `talos/control-plane/00-cluster.yaml` (the cluster does not enforce it), and weekly `FilesystemTrimConfig` in `talos/all/09-filesystem-trim.yaml` until the Proxmox disks have `discard=on`. kube-proxy is disabled (Cilium replaces it). After any topf or Talos bump, and before any apply, run `task talos:validate` (renders every node and runs `talosctl validate --mode metal`) and read `task talos:apply-node IP=<ip> MODE=no-reboot DRY_RUN=1` for each node. There is no CI gate for `talos/`; Flux Local only builds `kubernetes/**`.
- **`talos/secrets.sops.yaml` must exist.** If topf finds no secrets file it generates a new bundle instead of failing, and a config rendered from that cannot talk to the running cluster. The Taskfile checks for it first; restore it from Git, never regenerate it.
- **Etcd encryption key.** The cluster's Secrets are encrypted under secretbox key `key2`; a config that renders any other key name leaves a node's kube-apiserver unable to decrypt them and it never becomes ready (talhelper 3.1.17 rendered `key1`; seen on hiro-cmp-01 in `try` mode, 2026-10-08). topf renders `key2` with the same secret, and `task talos:apply-node` still runs `scripts/talos-check-etcd-encryption.sh` first and refuses a config whose key differs from the node's live one. Keep that check across tool and Talos bumps.
- **Applying config is not a no-op.** Each apply restarts the kubelet and the three control-plane static pods on that node and moves the VIP if it holds it. Do one node at a time, the etcd leader (`talosctl etcd status`) last: `task talos:apply-node IP=<ip> MODE=try TIMEOUT=5m`, confirm `curl -sk https://<ip>:6443/readyz` returns 200 or 401 and the node's control-plane pods are Ready, then repeat with `MODE=no-reboot`. topf renders the config and `talosctl apply-config` applies it, because `topf apply` has no try-mode timeout.

## Checking a Talos release before rolling it

Found evaluating the 1.13 ➔ 1.14 bump (#748, 2026-10-05); the method applies to every minor.

- **A Renovate PR body quotes a stale changelog.** For a `.0` release it links the `-beta1` section of `CHANGELOG.md`. Diff against
  the real notes: `gh release view v1.14.0 -R siderolabs/talos --json body`. Here the GA notes have no "noexec on EPHEMERAL"
  section (the commit that added it was followed by `fix: drop noexec for KUBELET, EPHEMERAL and CRI`), and they add sections the
  PR body lacks: a unified `--namespace` flag, `ExtensionServiceConfig`, Secure Boot lockdown, multipath via `EtcFileConfig`.
- **Longhorn here is the v1 data engine.** Its engine binaries live at the hard-coded `/var/lib/longhorn/engine-binaries/`, on
  EPHEMERAL, not under `defaultDataPath: /var/mnt/longhorn`. A future noexec on EPHEMERAL would break it, so re-read each minor's
  GA notes and `volumeconfig/system_volumes.go` for that. A separate effect that is real in 1.14: `UserVolumeConfig`
  `mount.secure` (default `true`) now implies noexec in code (1.13: nosuid,nodev), so `/var/mnt/longhorn` goes noexec on upgrade.
  That is replica data only and nothing executes there; verify after the roll with `talosctl get volumemountstatus`.
- **etcd metrics** stay pinned to 2381 through `listen-metrics-urls`, unaffected by the 2383 move.
- **Trim.** The default `FilesystemTrimConfig` (168h) is emitted by the 1.14 contract and absent on an upgrade of an old config.
  Talos trim is the node filesystem layer and Longhorn trim (`default-jobs.yaml`) is the guest-PVC layer. The Proxmox `scsi`
  disks have no `discard=on`, so a node trim reaches no host storage (revisit-register #17).
- **Scrub.** `FilesystemScrubConfig` is off by default; when on it runs `xfs_scrub -T -v` without `-n`, so it repairs online.
- **Image cache.** The Talos image cache is static boot-media content (an IMAGECACHE partition) that the installer image does not
  carry, with no runtime pinning; Spegel is the dynamic layer. Spegel's hosts path `/etc/cri/conf.d/hosts` is kept in 1.14.
- **extraMounts.** Kubelet `extraMounts` are gone from the 1.14 multi-document config (upstream #14411); this repo uses
  `UserVolumeConfig`, so it is not exposed.
- 1.14.2 enables `CONFIG_BLK_WBT`; cmp-05's system disk already shows about 16ms write latency, so watch it after the roll
  (`docs/runbook-node-disk-slow.md`).
