#!/usr/bin/env bash
# Shared helpers for the Silo qualification harness. Source, don't run.
# Everything runs in throwaway docker containers on a private network with
# generated credentials; nothing here reads production secrets or touches the cluster.
set -euo pipefail

SQ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SQ_DIR/../.." && pwd)"

# --- images under test ---
# Pinned by INDEX DIGEST, not tag: the docker daemon may be shared with other sessions that re-tag
# the same names (a sibling re-tagged pgsty/mc as amd64 under us). Tag shown for humans only.
# Override with env to retest another release. All three are multi-arch indexes; the host
# platform (SQ_PLATFORM, default = host) selects the manifest.
SILO_TAG="${SILO_TAG:-RELEASE.2026-10-26T00-00-00Z}"
SILO_IMG="${SILO_IMG:-docker.io/pgsty/silo@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7}"
MC_IMG="${MC_IMG:-docker.io/pgsty/mc@sha256:ce62c9053c69ce12a527a322345b5ad9f44b5f8a7b8189f82e516f2e3f30f1d8}"
FALLBACK_IMG="${FALLBACK_IMG:-docker.io/pgsty/minio@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372}"  # RELEASE.2026-08-04T00-00-00Z
# Upgrade-proxy source image (resolved to a digest by 05-upgrade-proxy.sh and recorded in its report).
PROXY_SRC_IMG="${PROXY_SRC_IMG:-docker.io/pgsty/minio:RELEASE.2026-04-17T00-00-00Z}"
THANOS_IMG="${THANOS_IMG:-quay.io/thanos/thanos:v0.42.4}"
GO_IMG="${GO_IMG:-docker.io/library/golang:1.24}"
SQ_PLATFORM="${SQ_PLATFORM:-}"   # e.g. linux/amd64 to run the emulated prod architecture
PLAT=(); [ -n "$SQ_PLATFORM" ] && PLAT=(--platform "$SQ_PLATFORM")

# Git ref the replayed manifests are read from (verbatim script text).
MANIFEST_REF="${MANIFEST_REF:-origin/main}"

# --- scratch ---
SQ_OUT="${SQ_OUT:-$SQ_DIR/out}"   # evidence + generated creds; git-ignored (see .gitignore)
SQ_NET="${SQ_NET:-sq-net}"
SQ_PREFIX="${SQ_PREFIX:-sq}"
mkdir -p "$SQ_OUT"

# Throwaway credentials, generated once per SQ_OUT and reused so re-runs match.
if [ ! -f "$SQ_OUT/creds.env" ]; then
  {
    echo "ROOT_USER=sqroot"
    echo "ROOT_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    echo "THANOS_AK=sq-thanos"; echo "THANOS_SK=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    echo "LOKI_AK=sq-loki";     echo "LOKI_SK=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    echo "RA_AK=sq-ra";         echo "RA_SK=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  } >"$SQ_OUT/creds.env"
fi
# shellcheck disable=SC1091
. "$SQ_OUT/creds.env"

net_up()   { docker network inspect "$SQ_NET" >/dev/null 2>&1 || docker network create "$SQ_NET" >/dev/null; }
net_down() { docker network rm "$SQ_NET" >/dev/null 2>&1 || true; }
cleanup()  { docker ps -aq --filter "name=^${SQ_PREFIX}-" | xargs -r docker rm -f >/dev/null 2>&1 || true; }

# digest_of: the digest an image ref resolves to ("(not pulled)" if absent). For @sha256 refs this is the ref itself.
digest_of() { case "$1" in *@sha256:*) echo "$1";; *) docker image inspect "$1" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "(not pulled)";; esac; }
arch_of() { docker image inspect "$1" --format '{{.Architecture}}' 2>/dev/null || echo "?"; }

# extract <manifest-path> -> prints the container's shell script (command[2]) exactly as committed.
extract_script() { python3 -I "$SQ_DIR/extract-script.py" "$MANIFEST_REF" "$1"; }

# new_volume <name> -> creates docker volume ${SQ_PREFIX}-vol-<name> chowned 1000:1000 (= the chart's fsGroup 1000)
new_volume() {
  local v="${SQ_PREFIX}-vol-$1"; docker volume rm "$v" >/dev/null 2>&1 || true; docker volume create "$v" >/dev/null
  docker run --rm -v "$v:/export" --user 0 --entrypoint /bin/sh "$SILO_IMG" -c 'chown 1000:1000 /export'
}

# start_server <name> <image> "<alias> [alias...]" [extra docker args...]
# Runs exactly what the minio 5.4.0 chart runs: uid 1000, MINIO_PROMETHEUS_AUTH_TYPE=public,
# volume at /export, /bin/sh -ce "/usr/bin/docker-entrypoint.sh minio server /export -S /etc/minio/certs/ ...".
start_server() {
  local name="$1" img="$2" alias="$3"; shift 3
  net_up
  docker rm -f "${SQ_PREFIX}-$name" >/dev/null 2>&1 || true
  local aliases=() a; for a in $alias; do aliases+=(--network-alias "$a"); done   # space-separated list
  docker run -d ${PLAT[@]+"${PLAT[@]}"} --name "${SQ_PREFIX}-$name" --network "$SQ_NET" "${aliases[@]}" \
    --user 1000:1000 \
    -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASS" \
    -e MINIO_PROMETHEUS_AUTH_TYPE=public \
    "$@" \
    --entrypoint /bin/sh "$img" \
    -ce "/usr/bin/docker-entrypoint.sh minio server /export -S /etc/minio/certs/ --address :9000 --console-address :9001" >/dev/null
}

# wait_ready <name> [secs]
wait_ready() {
  local name="$1" max="${2:-60}" i=0
  while [ $i -lt "$max" ]; do
    if docker run --rm --network "$SQ_NET" --entrypoint /usr/bin/curl "$SILO_IMG" -fsS "http://${SQ_PREFIX}-$name:9000/minio/health/ready" >/dev/null 2>&1; then
      echo "ready after ~${i}s"; return 0
    fi
    sleep 1; i=$((i+1))
  done
  echo "NOT ready after ${max}s"; docker logs "${SQ_PREFIX}-$name" 2>&1 | tail -20; return 1
}

# curl_in <url> [curl args] — curl from inside the docker network.
curl_in() { docker run --rm --network "$SQ_NET" --entrypoint /usr/bin/curl "$SILO_IMG" "$@"; }

