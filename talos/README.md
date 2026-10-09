# Talos configuration

Machine configs are rendered by [topf](https://github.com/postfinance/topf) from this directory. topf replaced
talhelper, which is archived (see [docs/spike-talhelper-replacement.md](../docs/spike-talhelper-replacement.md)).

```
talos/
├── topf.yaml            # cluster name/endpoint, talosVersion, kubernetesVersion, the node list (and each node's MAC)
├── schematic.yaml       # Image Factory schematic (system extensions); topf derives the installer image from it
├── secrets.sops.yaml    # the cluster's Talos secrets bundle, SOPS-encrypted. It must exist, see below
├── all/                 # patches for every node
├── control-plane/       # patches for control-plane nodes
└── clusterconfig/       # rendered output, gitignored: plaintext secrets
```

## How patches are applied

topf generates a default Talos config for `talosVersion`, then merges every file in `all/`, then `control-plane/`
(then `worker/` and `node/<host>/` if they exist), each directory in filename order, so the numeric prefixes decide the
order. A file is a strategic-merge patch: a plain mapping for the v1alpha1 document, or `---`-separated 1.14 documents
(`apiVersion: v1alpha1` + `kind:`). Documents with the same kind and name merge across files. Remove something the
generator adds with `$patch: delete`.

- `*.yaml` is used as written. `*.yaml.tpl` is rendered as a Go template first (`.Node.Host`, `.Node.IP`,
  `.Node.Data.<key>` from `data:` under a node in `topf.yaml`, `.Data.<key>` from the top-level `data:`). A template
  is parsed in full, comments included, so never write two opening braces in a comment.
- There is no environment substitution: write `$patch`, not `$$patch`.

## Working on it

```sh
task talos:validate            # render every node, run `talosctl validate --mode metal` on each
task talos:generate-config     # render to talos/clusterconfig/ (plaintext secrets, gitignored)
task talos:apply-node IP=<ip> MODE=no-reboot DRY_RUN=1   # Talos's own diff against the live node, changes nothing
```

An apply is not a no-op, and the order matters; see the Talos section of
[.github/copilot-instructions.md](../.github/copilot-instructions.md).

## Things that bite

- **`secrets.sops.yaml` missing**: topf generates a brand-new bundle instead of failing, and nothing rendered from it
  can reach the running cluster. The tasks check for the file first. Restore it from Git.
- **topf renders every Talos default** for the version, including ones this cluster has not chosen. Omitting a
  document does not remove it. See `all/10-disabled-defaults.yaml` and `all/09-filesystem-trim.yaml`.
- **v1alpha1 versus documents**: Talos 1.14 rejects a setting that exists in both. `task talos:validate` catches it.
- The files in `templates/config/talos/` are the old talhelper output of the initial cluster template and are not
  updated for topf.
