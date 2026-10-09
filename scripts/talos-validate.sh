#!/usr/bin/env bash
# Render every node's Talos machine config with topf and check each with
# `talosctl validate --mode metal`. Invoked by `task talos:validate`.
#
# Catches what Talos itself would reject at apply time, such as a setting in
# the v1alpha1 document that a 1.14 document now owns. There is no CI gate for
# talos/, so run it after any change there.
#
# The rendered files hold the cluster secrets in plaintext: they go to a private
# temporary directory that is removed on exit and nothing is printed from them.
set -o errexit
set -o nounset
set -o pipefail

talos_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../talos" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "${out}"' EXIT

cd "${talos_dir}"
topf --log-level warn render --output "${out}" >/dev/null

failed=0
for config in "${out}"/*.yaml; do
  node="$(basename "${config}" .yaml)"
  if talosctl validate --mode metal --config "${config}" >/dev/null 2>"${out}/${node}.err"; then
    echo "OK:   ${node}"
  else
    echo "FAIL: ${node}" >&2
    # validate prints only error text, never config content
    sed 's/^/      /' "${out}/${node}.err" >&2
    failed=1
  fi
done
exit "${failed}"
