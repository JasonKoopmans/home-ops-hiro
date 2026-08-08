#!/usr/bin/env bash
# Scaffold a new MCP server app under kubernetes/apps/mcp/.
#
# Copies one of the archetype templates in .taskfiles/mcp/resources/, renames
# __APP__ throughout, and registers the app in the mcp namespace group's
# kustomization.yaml. It deliberately does not commit or reconcile anything —
# the generated manifests still contain TODO markers that only a human (or an
# agent reading the upstream image) can resolve.
#
# Invoked via: task mcp:new name=<name> [archetype=native-http|stdio]
set -o errexit
set -o nounset
set -o pipefail

NAME="${1:-}"
ARCHETYPE="${2:-native-http}"
REPO_ROOT="${3:-$(git rev-parse --show-toplevel)}"

RESOURCES_DIR="${REPO_ROOT}/.taskfiles/mcp/resources"
GROUP_DIR="${REPO_ROOT}/kubernetes/apps/mcp"
GROUP_KUSTOMIZATION="${GROUP_DIR}/kustomization.yaml"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${NAME}" ]] || die "name is required (task mcp:new name=proxmox)"

# The mcp- prefix is the repo convention, so accept either form and normalise.
# Directory name, app name, Service name and hostname are all the same string.
NAME="${NAME#mcp-}"
APP="mcp-${NAME}"

# RFC 1123 label: hostnames derive directly from this, and the wildcard cert
# only covers a single label, so an invalid name fails late and confusingly.
[[ "${APP}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
  || die "'${APP}' is not a valid RFC 1123 label (lowercase alphanumerics and '-')"
[[ ${#APP} -le 63 ]] || die "'${APP}' exceeds 63 characters"

[[ -d "${RESOURCES_DIR}/${ARCHETYPE}" ]] \
  || die "unknown archetype '${ARCHETYPE}' (expected: native-http, stdio)"
[[ -f "${GROUP_KUSTOMIZATION}" ]] \
  || die "missing ${GROUP_KUSTOMIZATION} — is the mcp namespace group present?"

DEST="${GROUP_DIR}/${APP}"
[[ ! -e "${DEST}" ]] || die "${DEST} already exists — remove it or pick another name"

cp -R "${RESOURCES_DIR}/${ARCHETYPE}" "${DEST}"

# Rename the placeholder. Kept as a distinctive token so it cannot collide with
# Flux post-build variables like ${SECRET_DOMAIN}, which must survive verbatim.
while IFS= read -r -d '' file; do
  # BSD and GNU sed disagree on -i; write to a temp file to work on both.
  sed "s/__APP__/${APP}/g" "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
done < <(find "${DEST}" -type f -name '*.yaml' -print0)

ENTRY="  - ./${APP}/ks.yaml"
if grep -qF "${ENTRY}" "${GROUP_KUSTOMIZATION}"; then
  echo "already registered in $(basename "${GROUP_KUSTOMIZATION}"): ${ENTRY}"
else
  # Append to the resources list, then sort just the ./<app>/ks.yaml lines so
  # the file stays alphabetised without disturbing ./namespace.yaml at the top.
  printf '%s\n' "${ENTRY}" >> "${GROUP_KUSTOMIZATION}"
  awk -v out="${GROUP_KUSTOMIZATION}.tmp" '
    /^  - \.\/.*\/ks\.yaml$/ { ks[n++] = $0; next }
    { print > out }
    END {
      # asort() is a gawk extension; insertion sort keeps this portable.
      for (i = 0; i < n; i++) {
        v = ks[i]; j = i - 1
        while (j >= 0 && ks[j] > v) { ks[j+1] = ks[j]; j-- }
        ks[j+1] = v
      }
      for (i = 0; i < n; i++) print ks[i] > out
    }
  ' "${GROUP_KUSTOMIZATION}"
  mv "${GROUP_KUSTOMIZATION}.tmp" "${GROUP_KUSTOMIZATION}"
  echo "registered in $(basename "${GROUP_KUSTOMIZATION}"): ${ENTRY}"
fi

echo
echo "Scaffolded ${APP} (${ARCHETYPE}) at kubernetes/apps/mcp/${APP}"
echo
echo "Next:"
echo "  1. grep -rn TODO kubernetes/apps/mcp/${APP}   # resolve every marker"
echo "  2. read docs/mcp-onboarding.md                # contract + known traps"
echo "  3. kustomize build kubernetes/apps/mcp/${APP}/app"
echo "  4. open a PR — Flux Local's diff is the real gate"
echo
echo "The UID pin and any host-allow-list setting can only be resolved after"
echo "the first deploy. Both are marked TODO in the HelmRelease."
