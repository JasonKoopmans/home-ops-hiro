#!/usr/bin/env bash
# Refuse to apply a rendered Talos machine config whose Secret-at-rest (etcd)
# encryption key differs from the one the node's kube-apiserver runs with.
#
# kube-apiserver stores the secretbox key NAME next to every encrypted Secret.
# A config that renders the same secret under a different name (talhelper
# 3.1.17 rendered "key1" where this cluster uses "key2"; topf renders "key2")
# leaves the apiserver unable to decrypt anything: the cacher loops,
# informer-sync never passes and /readyz stays 500. Found with a `--mode=try`
# apply on hiro-cmp-01 on 2026-10-08. Kept as a guard for any future generator
# or Talos bump.
#
# Compares the secretbox (name, secret) pairs of the node's live
# encryptionconfig.yaml with the generated config. Secret values are compared
# but never printed.
#
# Usage: talos-check-etcd-encryption.sh <node-ip> <rendered-config.yaml>
# Invoked by `task talos:apply-node`. Set TALOS_SKIP_ETCD_KEY_CHECK=1 only for a
# deliberate key rotation.
set -o errexit
set -o nounset
set -o pipefail

node="${1:?usage: $0 <node-ip> <generated-config.yaml>}"
config="${2:?usage: $0 <node-ip> <generated-config.yaml>}"

live_path="/system/secrets/kubernetes/kube-apiserver/encryptionconfig.yaml"

if [[ "${TALOS_SKIP_ETCD_KEY_CHECK:-}" == "1" ]]; then
  echo "WARNING: etcd encryption key check skipped (TALOS_SKIP_ETCD_KEY_CHECK=1)" >&2
  exit 0
fi

if [[ ! -f "${config}" ]]; then
  echo "ERROR: ${config} not found; run 'task talos:generate-config' first" >&2
  exit 1
fi

# "<name> <secret>" per secretbox key, one line each.
live_pairs="$(talosctl --nodes "${node}" read "${live_path}" |
  yq '.resources[].providers[].secretbox.keys[] | .name + " " + .secret')"

# Generated config: the 1.14 KubeEtcdEncryptionConfig document, or the legacy
# v1alpha1 cluster.secretboxEncryptionSecret, which Talos renders as "key2".
new_style="$(yq 'select(.kind == "KubeEtcdEncryptionConfig") |
  .config.resources[].providers[].secretbox.keys[] | .name + " " + .secret' "${config}")"
legacy="$(yq 'select(.cluster.secretboxEncryptionSecret != null) |
  "key2 " + .cluster.secretboxEncryptionSecret' "${config}")"
rendered_pairs="$(printf '%s\n%s\n' "${new_style}" "${legacy}" | sed '/^$/d')"

if [[ -z "${live_pairs}" ]]; then
  echo "ERROR: no secretbox key found in ${node}:${live_path}" >&2
  exit 1
fi
if [[ -z "${rendered_pairs}" ]]; then
  echo "ERROR: no etcd encryption key found in ${config}" >&2
  echo "       (no KubeEtcdEncryptionConfig document and no cluster.secretboxEncryptionSecret)" >&2
  exit 1
fi

names() { awk '{print $1}' <<<"$1" | sort | paste -sd, -; }

if [[ "$(sort <<<"${live_pairs}")" != "$(sort <<<"${rendered_pairs}")" ]]; then
  echo "ERROR: ${config} would change the etcd encryption key of ${node}." >&2
  echo "  live key name(s):      $(names "${live_pairs}")" >&2
  echo "  generated key name(s): $(names "${rendered_pairs}")" >&2
  if [[ "$(names "${live_pairs}")" == "$(names "${rendered_pairs}")" ]]; then
    echo "  The key name(s) match but the secret value differs." >&2
  fi
  echo "  A different name or secret makes kube-apiserver unable to decrypt existing Secrets." >&2
  echo "  Check that talos/secrets.sops.yaml is the bundle this cluster was built from" >&2
  echo "  (secrets.secretboxencryptionsecret) and that no patch under talos/ replaces" >&2
  echo "  KubeEtcdEncryptionConfig. Not applying." >&2
  exit 1
fi

echo "OK: etcd encryption key ($(names "${live_pairs}")) matches the node's live key"
