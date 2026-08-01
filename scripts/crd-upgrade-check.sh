#!/usr/bin/env bash
# crd-upgrade-check.sh
#
# Sanity-check a CRD-chart version bump — the `helmrelease-crds.yaml` files that
# version CRDs independently of their operator image — *before* Flux applies it.
#
# The Flux Local workflow proves the manifests render. It does not prove the
# apiserver would admit them, and it does not prove the CRs already in Git (or
# already in the cluster) still validate against the new schemas. This does.
#
# Tier 1 — CRD object safety
#   1A  CRDs present in the old chart and absent in the new one            HIGH
#   1B  served/storage versions dropped, scope or names.kind changed       HIGH
#   1C  live `status.storedVersions` no longer served by the new chart     HIGH
#       (needs --live and a reachable cluster; read-only)
# Tier 2 — schema delta between the two chart versions                     WARN
#   added `required`, narrowed enums, removed properties, added/changed
#   `x-kubernetes-validations` (CEL). Reported, never auto-judged.
# Tier 3 — CR admission validation                                         HIGH
#   Every CR in the *rendered* cluster manifest (flux-local build all, so
#   chart-generated PrometheusRules/ServiceMonitors are included) checked
#   against the NEW CRDs, via one of two backends:
#     --mode=apiserver  disposable kind cluster + kubectl apply --dry-run=server
#                       (the only backend that evaluates CEL and defaulting)
#     --mode=schema     CRD -> JSON Schema + kubeconform (fast, offline, no CEL)
#
# Every run ends with a "NOT VERIFIED BY THIS CHECK" section. Read it.
#
# Exit codes: 0 = no HIGH findings, 1 = at least one HIGH finding,
#             2 = usage or tooling error.
#
# Never reads age.key, never decrypts SOPS, never prints secret material. All
# scratch state lives in a mktemp -d removed on exit; nothing is ever written
# inside the repository working tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pinned toolchain. flux-local and kind are not in .mise.toml (flux-local ships
# as a container image, kind needs a container runtime anyway); both are
# resolved at run time and their absence downgrades a tier to SKIP, never to a
# failure.
#
# The version lines below are bare on purpose: .renovaterc.json5's custom
# manager matches `# renovate: …` followed by a `KEY=value` line and captures
# \S+ as the version, so a quoted "image:tag" would capture the quotes too.
# renovate: datasource=docker depName=ghcr.io/allenporter/flux-local
FLUX_LOCAL_VERSION=v8.0.1
FLUX_LOCAL_IMAGE="ghcr.io/allenporter/flux-local:${FLUX_LOCAL_VERSION}"
# renovate: datasource=docker depName=kindest/node
KIND_NODE_VERSION=v1.36.1
KIND_NODE_IMAGE="kindest/node:${KIND_NODE_VERSION}"
KUBECTL_TIMEOUT="30s"
KUBECTL_TIMEOUT_LONG="300s"
# flux-local hardcodes a 60s per-`helm template` timeout and fans out 20 at a
# time; on a small container runtime a cold run can trip it. Retry once.
FLUX_LOCAL_ATTEMPTS=2
# Keep a big chart bump readable.
MAX_ITEMS=8
# Max findings shown per (severity, app, category) in the report.
MAX_PER_CATEGORY=15

OPT_PATH=""
OPT_BASE=""
OPT_MODE="schema"
OPT_LIVE=0
OPT_RENDERED=""
OPT_APISERVER_KUBECONFIG=""
OPT_LAX_SCHEMA=0
OPT_SKIP_TIER3=0
OPT_MARKDOWN=""

usage() {
  cat <<'EOF'
Usage: crd-upgrade-check.sh [options]

  --path <group>/<app>    Check one app (e.g. monitoring/kube-prometheus-stack).
                          Default: every kubernetes/**/helmrelease-crds.yaml.
  --base <git-ref>        Baseline ref for the "old" chart version.
                          Default: origin/main, then main.
  --mode schema|apiserver Tier 3 backend. Default: schema.
                          apiserver spins up a disposable kind cluster and is
                          the only backend that evaluates CEL and defaulting.
  --live                  Enable the cluster-dependent checks: Tier 1C
                          (status.storedVersions) and validation of the CRs
                          that exist in the live cluster but not in Git.
                          Read-only; skips cleanly with no kubeconfig.
  --rendered <file>       Use a pre-rendered cluster manifest instead of
                          invoking flux-local (CI renders once and reuses).
  --apiserver-kubeconfig <file>
                          Kubeconfig of a disposable cluster to use for
                          --mode=apiserver instead of creating one with kind.
                          NEVER point this at the production cluster.
  --lax-schema            --mode=schema only: do not synthesise
                          `additionalProperties: false`, so unknown/removed
                          fields go unreported.
  --skip-tier3            Skip CR admission validation entirely.
  --markdown <file>       Also write the report as Markdown (CI summaries).
  -h, --help              Show this help.
EOF
}

msg()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
  # Accept both "--opt value" and "--opt=value".
  case "$1" in
    --*=*)
      set -- "${1%%=*}" "${1#*=}" "${@:2}"
      ;;
  esac
  case "$1" in
    --path|--base|--mode|--rendered|--apiserver-kubeconfig|--markdown)
      [ $# -ge 2 ] || die "missing value for $1"
      case "$1" in
        --path)                 OPT_PATH="$2" ;;
        --base)                 OPT_BASE="$2" ;;
        --mode)                 OPT_MODE="$2" ;;
        --rendered)             OPT_RENDERED="$2" ;;
        --apiserver-kubeconfig) OPT_APISERVER_KUBECONFIG="$2" ;;
        --markdown)             OPT_MARKDOWN="$2" ;;
      esac
      shift 2 ;;
    --live)       OPT_LIVE=1; shift ;;
    --lax-schema) OPT_LAX_SCHEMA=1; shift ;;
    --skip-tier3) OPT_SKIP_TIER3=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$OPT_MODE" in
  schema|apiserver) ;;
  *) die "--mode must be 'schema' or 'apiserver'" ;;
esac

for dep in git helm yq jq awk; do
  have "$dep" || die "$dep not found (pinned in .mise.toml — run 'mise install')"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/crd-upgrade-check.XXXXXX")"
KIND_CLUSTER=""
cleanup() {
  local rc=$?
  if [ -n "$KIND_CLUSTER" ] && have kind; then
    kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
  return "$rc"
}
trap cleanup EXIT

# Keep helm's caches inside the scratch dir: a run never mutates the user's helm
# config and never leaves anything behind.
export HELM_CACHE_HOME="$TMP/helm/cache"
export HELM_CONFIG_HOME="$TMP/helm/config"
export HELM_DATA_HOME="$TMP/helm/data"
mkdir -p "$HELM_CACHE_HOME" "$HELM_CONFIG_HOME" "$HELM_DATA_HOME"

FINDINGS="$TMP/findings.tsv"   # SEVERITY \t APP \t CATEGORY \t MESSAGE \t REMEDIATION
SKIPS="$TMP/skips.txt"
NOTES="$TMP/notes.txt"         # extra "not verified" lines discovered at run time
: >"$FINDINGS"; : >"$SKIPS"; : >"$NOTES"

# Findings are appended from inside pipelines and subshells, so they live in a
# file rather than a shell array. Tabs and newlines are the record separators,
# so they are squeezed out of the free-text fields.
finding() { # severity app category message remediation
  local m r
  m="$(printf '%s' "$4" | tr '\t\n' '  ')"
  r="$(printf '%s' "$5" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$m" "$r" >>"$FINDINGS"
}
skipped() { printf '%s\n' "$*" >>"$SKIPS"; }
note()    { printf '%s\n' "$*" >>"$NOTES"; }

# ---------------------------------------------------------------------------
# jq programs (kept in files so quoting stays sane and shellcheck stays happy)
# ---------------------------------------------------------------------------

cat >"$TMP/facts.jq" <<'JQ'
# Flatten an OpenAPI v3 schema into comparable facts keyed by a human-readable
# schema path. Single pass over `paths` — the Prometheus CRD is ~1MB of JSON.
#
# CAVEAT: ppath is lossy. Dropping every "properties" segment makes the output
# readable but is not injective — two distinct schema locations can normalise to
# the same string, and the group_by at the bottom then unions their value sets.
# A collision blurs one Tier 2 added/removed diff into another, which can
# produce a spurious WARN or hide a real one. Bounded on purpose: Tier 2 is
# descriptive and never emits HIGH, so a collision cannot change the exit code.
# Key on the raw path array instead if Tier 2 is ever promoted to blocking.
def ppath($p):
  ( ( $p
      | map(select(. != "properties"))
      | map(if . == "items" then "[]"
            elif type == "number" then "[" + tostring + "]"
            else "." + tostring end)
      | join("") ) as $s
    | if $s == "" then "(root)" else $s end );

[ paths as $p
  | select(($p | length) > 0)
  | ($p[-1]) as $k
  | select($k == "required" or $k == "enum" or $k == "properties"
           or $k == "x-kubernetes-validations")
  # A property literally named e.g. "required" sits under a "properties" map;
  # that is data, not a schema keyword.
  | select(($p | length) < 2 or $p[-2] != "properties")
  | getpath($p) as $v
  | ppath($p[:-1]) as $path
  | if   $k == "required"                 and ($v | type) == "array"
    then {kind: "required",   path: $path, values: ($v | map(tostring) | sort)}
    elif $k == "enum"                     and ($v | type) == "array"
    then {kind: "enum",       path: $path, values: ($v | map(tostring) | sort)}
    elif $k == "properties"               and ($v | type) == "object"
    then {kind: "properties", path: $path, values: ($v | keys)}
    elif $k == "x-kubernetes-validations" and ($v | type) == "array"
    then {kind: "cel",        path: $path,
          values: ($v | map(.rule // "" | tostring) | sort)}
    else empty end ]
| group_by(.kind + " " + .path)
| map(.[0] * {values: (map(.values) | add | unique)})
JQ

cat >"$TMP/schemadelta.jq" <<'JQ'
# Compare two fact sets from facts.jq.
# Emits TSV: SEVERITY \t CATEGORY \t MESSAGE \t REMEDIATION
# Tier 2 is descriptive only: nothing here is ever HIGH.
def idx: INDEX(.kind + " " + .path);
def clip($limit): if (length > $limit)
                  then (.[0:$limit] + ["(+\(length - $limit) more)"]) else . end;
def fmt: clip($max) | join(", ");

($o[0] | idx) as $O
| ($n[0] | idx) as $N
| [ $N | to_entries[]
    | .key as $key | .value as $new
    | ($O[$key] // null) as $old
    | select($old != null)
    | ($new.values - $old.values) as $added
    | ($old.values - $new.values) as $removed
    | if $new.kind == "required" and ($added | length) > 0 then
        ["WARN", "tier2/required",
         "\($crd) \($ver): new required field(s) at \($new.path): \($added | fmt)",
         "Confirm every CR of this kind sets them, or that the chart defaults them."]
      elif $new.kind == "enum" and ($removed | length) > 0 then
        ["WARN", "tier2/enum",
         "\($crd) \($ver): enum narrowed at \($new.path), dropped: \($removed | fmt)",
         "Grep the rendered manifests for the dropped value(s) before merging."]
      elif $new.kind == "properties" and ($removed | length) > 0 then
        ["WARN", "tier2/removed-property",
         "\($crd) \($ver): propert(y|ies) removed at \($new.path): \($removed | fmt)",
         "Removed fields are silently dropped on apply — check nothing depends on them."]
      elif $new.kind == "cel" and (($added | length) > 0 or ($removed | length) > 0) then
        ["WARN", "tier2/cel",
         "\($crd) \($ver): x-kubernetes-validations changed at \($new.path)"
         + (if ($added   | length) > 0 then "; added: \($added | fmt)"     else "" end)
         + (if ($removed | length) > 0 then "; removed: \($removed | fmt)" else "" end),
         "CEL is only evaluated by --mode=apiserver. Run that mode before merging."]
      else empty end ]
+ [ $N | to_entries[]
    | .key as $key | .value as $new
    | select(($O[$key] // null) == null)
    | select($new.kind == "cel")
    | ["WARN", "tier2/cel",
       "\($crd) \($ver): new x-kubernetes-validations block at \($new.path): \($new.values | fmt)",
       "CEL is only evaluated by --mode=apiserver. Run that mode before merging."] ]
| .[] | @tsv
JQ

cat >"$TMP/harden.jq" <<'JQ'
# CRD openAPIV3Schema -> JSON Schema usable by kubeconform.
#
# Verified against prometheus-operator-crds 29.0.0 / 30.0.1:
#   * `x-kubernetes-int-or-string: true` nodes carry no `type` (sometimes an
#     anyOf integer/string plus a `pattern`), which is already permissive in
#     JSON Schema — no conversion needed, no false positives.
#   * `x-kubernetes-preserve-unknown-fields: true` must stop the walk, otherwise
#     the synthesised additionalProperties:false below would reject the very
#     free-form content that field exists to allow.
#   * kubeconform's -strict does NOT synthesise additionalProperties:false (it
#     only expands {{.StrictSuffix}} and rejects duplicate YAML keys), so unknown
#     and removed fields are invisible unless we add it here.
#   * Logical junctors are left alone: a branch of anyOf/oneOf/allOf may list a
#     subset of properties, and closing it would reject valid documents.
def harden:
  if type == "object" then
    if (.["x-kubernetes-preserve-unknown-fields"] == true) then .
    else
      ( to_entries
        | map(if (.key == "anyOf" or .key == "oneOf" or .key == "allOf" or .key == "not")
              then . else .value |= harden end)
        | from_entries )
      | ( if (has("properties")
              and (has("additionalProperties") | not)
              and (has("anyOf") | not) and (has("oneOf") | not)
              and (has("allOf") | not) and (has("not")   | not))
          then . + {"additionalProperties": false} else . end )
    end
  elif type == "array" then map(harden)
  else . end;

(if $lax == 1 then . else harden end)
+ {"$schema": "http://json-schema.org/draft-07/schema#"}
JQ

# ---------------------------------------------------------------------------
# baseline ref
# ---------------------------------------------------------------------------

resolve_base_ref() {
  local ref
  if [ -n "$OPT_BASE" ]; then
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "${OPT_BASE}^{commit}" >/dev/null 2>&1; then
      printf '%s' "$OPT_BASE"; return 0
    fi
    die "baseline ref '${OPT_BASE}' does not resolve. Failing command:
    git -C '${REPO_ROOT}' rev-parse --verify '${OPT_BASE}^{commit}'"
  fi
  for ref in origin/main main; do
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"; return 0
    fi
  done
  die "no baseline ref resolved — refusing to run without one. Failing commands:
    git -C '${REPO_ROOT}' rev-parse --verify 'origin/main^{commit}'
    git -C '${REPO_ROOT}' rev-parse --verify 'main^{commit}'
  Fetch the default branch (git fetch origin main) or pass --base <ref>."
}

BASE_REF="$(resolve_base_ref)"

# ---------------------------------------------------------------------------
# target discovery
# ---------------------------------------------------------------------------

discover_targets() {
  local f
  if [ -n "$OPT_PATH" ]; then
    f="${REPO_ROOT}/kubernetes/apps/${OPT_PATH}/app/helmrelease-crds.yaml"
    [ -f "$f" ] || die "no helmrelease-crds.yaml under kubernetes/apps/${OPT_PATH}/app/"
    printf '%s\n' "$f"
    return 0
  fi
  find "${REPO_ROOT}/kubernetes" -type f -name 'helmrelease-crds.yaml' | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# chart source resolution
# ---------------------------------------------------------------------------

# Locate the chart source (HelmRepository / OCIRepository) the HelmRelease points
# at, in the same app directory, at a given git ref ("" = working tree).
# Echoes: <chart-or-oci-url> \t <repo-url-or-"-"> \t <version>
# The middle field uses "-" rather than "" because tab is IFS whitespace: `read`
# collapses runs of it, so an empty middle field would shift the version away.
resolve_chart_source() { # app_dir hr_json ref app
  local app_dir="$1" hr="$2" ref="$3" app="$4"
  local src_kind src_name chart version url f obj rel

  src_kind="$(printf '%s' "$hr" | jq -r '
     if   (.spec.chart.spec.sourceRef.kind // "") != "" then .spec.chart.spec.sourceRef.kind
     elif (.spec.chartRef.kind // "")             != "" then .spec.chartRef.kind
     else "" end')"
  src_name="$(printf '%s' "$hr" | jq -r '
     if   (.spec.chart.spec.sourceRef.name // "") != "" then .spec.chart.spec.sourceRef.name
     elif (.spec.chartRef.name // "")             != "" then .spec.chartRef.name
     else "" end')"

  if [ -z "$src_kind" ] || [ -z "$src_name" ]; then
    msg "   unsupported source: ${app} HelmRelease has neither spec.chart.spec.sourceRef nor spec.chartRef"
    return 1
  fi

  obj=""
  for f in "$app_dir"/*.yaml; do
    [ -e "$f" ] || continue
    rel="${f#"$REPO_ROOT"/}"
    if [ -n "$ref" ]; then
      obj="$(git -C "$REPO_ROOT" show "${ref}:${rel}" 2>/dev/null \
             | yq -o=json -I=0 "select(.kind == \"${src_kind}\" and .metadata.name == \"${src_name}\")" 2>/dev/null || true)"
    else
      obj="$(yq -o=json -I=0 "select(.kind == \"${src_kind}\" and .metadata.name == \"${src_name}\")" "$f" 2>/dev/null || true)"
    fi
    [ -n "$obj" ] && break
  done

  if [ -z "$obj" ]; then
    msg "   unsupported source: no ${src_kind}/${src_name} in ${app_dir#"$REPO_ROOT"/} at ref '${ref:-working tree}'"
    return 1
  fi

  case "$src_kind" in
    HelmRepository)
      url="$(printf '%s' "$obj" | jq -r '.spec.url // ""')"
      chart="$(printf '%s' "$hr" | jq -r '.spec.chart.spec.chart // ""')"
      version="$(printf '%s' "$hr" | jq -r '.spec.chart.spec.version // ""')"
      if [ -z "$url" ] || [ -z "$chart" ] || [ -z "$version" ]; then
        msg "   unsupported source: HelmRepository/${src_name} is missing url, chart or version"
        return 1
      fi
      printf '%s\t%s\t%s\n' "$chart" "$url" "$version"
      ;;
    OCIRepository)
      # OCIRepository carries the version in spec.ref.tag; the HelmRelease only
      # references the source by name (chartRef).
      url="$(printf '%s' "$obj" | jq -r '.spec.url // ""')"
      version="$(printf '%s' "$obj" | jq -r '.spec.ref.tag // ""')"
      if [ -z "$url" ] || [ -z "$version" ]; then
        msg "   unsupported source: OCIRepository/${src_name} is missing spec.url or spec.ref.tag (digest and semver ranges are not supported)"
        return 1
      fi
      printf '%s\t%s\t%s\n' "$url" "-" "$version"
      ;;
    *)
      msg "   unsupported source kind '${src_kind}' for ${app} — refusing to guess"
      return 1
      ;;
  esac
}

extract_values() { # hr_json outfile
  if printf '%s' "$1" | jq -e '(.spec.values? // {}) | length > 0' >/dev/null 2>&1; then
    printf '%s' "$1" | jq '.spec.values' | yq -p=json -o=yaml '.' >"$2"
  else
    : >"$2"
  fi
}

# helm template the chart, keeping only CustomResourceDefinition documents, as
# NDJSON (one CRD per line).
render_crds() { # chart url version values_file out_ndjson
  local chart="$1" url="$2" version="$3" values="$4" out="$5"
  local raw="$TMP/helm-out.yaml"
  local args
  args=(template crd-upgrade-check "$chart" --version "$version" --include-crds --skip-tests)
  # "-" means the chart reference is already a full oci:// URL.
  if [ -n "$url" ] && [ "$url" != "-" ]; then args+=(--repo "$url"); fi
  if [ -s "$values" ]; then args+=(--values "$values"); fi
  if ! helm "${args[@]}" >"$raw" 2>"$TMP/helm-err.txt"; then
    msg "   helm template failed for ${chart} ${version}:"
    sed 's/^/     /' "$TMP/helm-err.txt" >&2
    rm -f "$raw"
    return 1
  fi
  yq -o=json -I=0 'select(.kind == "CustomResourceDefinition")' "$raw" >"$out"
  rm -f "$raw"
  if [ ! -s "$out" ]; then
    msg "   chart ${chart} ${version} rendered no CustomResourceDefinition documents"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# live cluster (read-only, opt-in, never blocks)
# ---------------------------------------------------------------------------

LIVE_OK=0
LIVE_REASON="not requested (--live)"
probe_live_cluster() {
  local kc found
  if ! have kubectl; then LIVE_REASON="kubectl not found"; return 1; fi
  if [ -n "${KUBECONFIG:-}" ]; then
    # KUBECONFIG is a :-separated precedence list and client-go silently skips
    # entries that do not exist, so only an entirely absent list means there is
    # no config. Testing just the first entry would skip the live checks while
    # kubectl itself would have worked fine off a later one.
    found=0
    while IFS= read -r kc; do
      [ -n "$kc" ] || continue
      if [ -f "$kc" ]; then found=1; break; fi
    done < <(printf '%s' "$KUBECONFIG" | tr ':' '\n')
    if [ "$found" -eq 0 ]; then
      LIVE_REASON="no file in KUBECONFIG (${KUBECONFIG}) exists"
      return 1
    fi
  elif [ ! -f "${HOME}/.kube/config" ]; then
    LIVE_REASON="no kubeconfig (KUBECONFIG unset and ~/.kube/config missing)"
    return 1
  fi
  if ! kubectl --request-timeout="$KUBECTL_TIMEOUT" api-versions >/dev/null 2>&1; then
    LIVE_REASON="cluster not reachable within ${KUBECTL_TIMEOUT}"
    return 1
  fi
  LIVE_OK=1
  LIVE_REASON="reachable (read-only)"
  return 0
}

# ---------------------------------------------------------------------------
# rendered cluster manifest (Tier 3 input)
# ---------------------------------------------------------------------------

RENDERED=""
RENDER_REASON=""

build_rendered_manifest() {
  local out work attempt
  if [ -n "$OPT_RENDERED" ]; then
    if [ ! -s "$OPT_RENDERED" ]; then
      RENDER_REASON="--rendered file '${OPT_RENDERED}' is missing or empty"
      return 1
    fi
    RENDERED="$OPT_RENDERED"
    return 0
  fi

  out="$TMP/flux-local-out/rendered.yaml"
  work="$TMP/flux-local-workspace"
  # flux-local shells out to `flux build ks`, which *writes* a generated
  # kustomization.yaml into the tree it is pointed at, and to
  # `git rev-parse --show-toplevel`, which fails in a linked worktree whose
  # .git is a file. Both are handled by rendering a throwaway copy — the repo
  # working tree is never written to.
  rm -rf "$work"; mkdir -p "$work" "$TMP/flux-local-out"
  cp -R "${REPO_ROOT}/kubernetes" "$work/kubernetes"
  git -C "$work" init -q >/dev/null 2>&1 || true

  if have flux-local; then
    for attempt in $(seq 1 "$FLUX_LOCAL_ATTEMPTS"); do
      msg "   flux-local build all (native, attempt ${attempt}/${FLUX_LOCAL_ATTEMPTS})"
      if ( cd "$work" && flux-local build all --enable-helm \
             --output-file "$out" kubernetes/flux/cluster ) >"$TMP/flux-local.log" 2>&1; then
        [ -s "$out" ] && { RENDERED="$out"; return 0; }
      fi
    done
  elif have docker; then
    for attempt in $(seq 1 "$FLUX_LOCAL_ATTEMPTS"); do
      msg "   flux-local build all (${FLUX_LOCAL_IMAGE}, attempt ${attempt}/${FLUX_LOCAL_ATTEMPTS})"
      if docker run --rm \
           -v "${work}:/workspace" -v "${TMP}/flux-local-out:/out" -w /workspace \
           "$FLUX_LOCAL_IMAGE" \
           build all --enable-helm --output-file /out/rendered.yaml \
           kubernetes/flux/cluster >"$TMP/flux-local.log" 2>&1; then
        [ -s "$out" ] && { RENDERED="$out"; return 0; }
      fi
    done
  else
    RENDER_REASON="neither a flux-local binary nor docker is available"
    return 1
  fi

  RENDER_REASON="flux-local build all failed after ${FLUX_LOCAL_ATTEMPTS} attempt(s): $(tail -n 1 "$TMP/flux-local.log" 2>/dev/null || echo 'no output')"
  return 1
}

# ---------------------------------------------------------------------------
# Tier 3 backends
# ---------------------------------------------------------------------------

APISERVER_KUBECONFIG=""
APISERVER_REASON=""

# Bring up (or adopt) a disposable apiserver. Never touches the ambient
# KUBECONFIG — --mode=apiserver must never dry-run against production.
ensure_apiserver() {
  [ -n "$APISERVER_KUBECONFIG" ] && return 0
  if [ -n "$OPT_APISERVER_KUBECONFIG" ]; then
    if [ ! -f "$OPT_APISERVER_KUBECONFIG" ]; then
      APISERVER_REASON="--apiserver-kubeconfig '${OPT_APISERVER_KUBECONFIG}' does not exist"
      return 1
    fi
    if ! kubectl --kubeconfig "$OPT_APISERVER_KUBECONFIG" \
           --request-timeout="$KUBECTL_TIMEOUT" api-versions >/dev/null 2>&1; then
      APISERVER_REASON="cluster in --apiserver-kubeconfig is not reachable"
      return 1
    fi
    APISERVER_KUBECONFIG="$OPT_APISERVER_KUBECONFIG"
    return 0
  fi
  have kubectl || { APISERVER_REASON="kubectl not found"; return 1; }
  have kind    || { APISERVER_REASON="kind not found — install it or use --mode=schema"; return 1; }
  # kind is driven through the `docker` CLI here; podman is only usable via its
  # docker-compatible shim, so probing for `podman` by name would be misleading.
  have docker  || { APISERVER_REASON="no docker CLI for kind (podman works only via its docker shim) — use --mode=schema"; return 1; }

  KIND_CLUSTER="crd-upgrade-check-$$"
  msg "   creating ephemeral kind cluster ${KIND_CLUSTER} (${KIND_NODE_IMAGE})"
  if ! kind create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE" \
         --kubeconfig "$TMP/kind.kubeconfig" --wait 180s >"$TMP/kind.log" 2>&1; then
    APISERVER_REASON="kind create cluster failed: $(tail -n 3 "$TMP/kind.log" | tr '\n' ' ')"
    # A failed create can still leave containers behind, so tear down before
    # clearing the name — the EXIT trap skips cleanup once this is empty.
    kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
    KIND_CLUSTER=""
    return 1
  fi
  APISERVER_KUBECONFIG="$TMP/kind.kubeconfig"
  return 0
}

# Install the NEW CRDs the way Flux does. Flux applies CRDs with CreateReplace,
# not client-side apply — verified necessary: the Prometheus CRD is ~834KB and
# `kubectl apply` (client-side) fails on it with "metadata.annotations: Too
# long: may not be more than 262144 bytes", because of the
# last-applied-configuration annotation. `create` (like `apply --server-side`)
# never writes that annotation.
install_crds_into_apiserver() { # crds_ndjson
  local ndjson="$1" yaml="$TMP/crds-to-install.yaml"
  yq -p=json -o=yaml '.' "$ndjson" >"$yaml"
  if ! kubectl --kubeconfig "$APISERVER_KUBECONFIG" --request-timeout="$KUBECTL_TIMEOUT_LONG" \
         create -f "$yaml" >"$TMP/crd-install.log" 2>&1; then
    if ! kubectl --kubeconfig "$APISERVER_KUBECONFIG" --request-timeout="$KUBECTL_TIMEOUT_LONG" \
           replace -f "$yaml" >>"$TMP/crd-install.log" 2>&1; then
      return 1
    fi
  fi
  kubectl --kubeconfig "$APISERVER_KUBECONFIG" --request-timeout="$KUBECTL_TIMEOUT_LONG" \
    wait --for=condition=Established --all crd >/dev/null 2>&1 || true
  return 0
}

# The disposable cluster has no namespaces, and a namespaced dry-run against a
# missing namespace fails with NotFound — a false positive that has nothing to
# do with the CRD bump. Create the namespaces the CRs reference first.
ensure_namespaces() { # crs_yaml
  local ns
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    kubectl --kubeconfig "$APISERVER_KUBECONFIG" --request-timeout="$KUBECTL_TIMEOUT" \
      create namespace "$ns" >/dev/null 2>&1 || true
  done < <(yq -o=json -I=0 '.' "$1" 2>/dev/null \
           | jq -r 'select(type == "object") | .metadata.namespace // empty' \
           | LC_ALL=C sort -u)
}

# Build one JSON Schema per group/kind_version for kubeconform.
# Verified: kubeconform's -schema-location template exposes .Group,
# .ResourceKind (lowercased), .ResourceAPIVersion (version only), .KindSuffix,
# .StrictSuffix and .NormalizedKubernetesVersion — so a group-qualified path
# disambiguates same-kind-different-group and multi-version CRDs.
build_json_schemas() { # crds_ndjson outdir
  local ndjson="$1" outdir="$2" line group kind ver
  mkdir -p "$outdir"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    group="$(printf '%s' "$line" | jq -r '.spec.group')"
    kind="$(printf '%s' "$line" | jq -r '.spec.names.kind | ascii_downcase')"
    mkdir -p "${outdir}/${group}"
    while IFS= read -r ver; do
      [ -n "$ver" ] || continue
      printf '%s' "$line" \
        | jq -c --arg v "$ver" \
            '.spec.versions[] | select(.name == $v) | (.schema.openAPIV3Schema // {"type":"object"})' \
        | jq -c --argjson lax "$OPT_LAX_SCHEMA" --from-file "$TMP/harden.jq" \
            >"${outdir}/${group}/${kind}_${ver}.json"
    done < <(printf '%s' "$line" | jq -r '.spec.versions[].name')
  done <"$ndjson"
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

sev_rank() { case "$1" in HIGH) printf '0' ;; WARN) printf '1' ;; *) printf '2' ;; esac; }

sorted_findings() {
  local sev app categ text rem
  while IFS=$'\t' read -r sev app categ text rem; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(sev_rank "$sev")" "$sev" "$app" "$categ" "$text" "$rem"
  done <"$FINDINGS" | LC_ALL=C sort -s -t$'\t' -k1,1 | cut -f2-
}

# A large downgrade can produce hundreds of Tier 2 rows. Keep the report
# readable by showing at most MAX_PER_CATEGORY per (severity, app, category);
# the header counts and the tier2/summary line stay truthful.
capped_findings() {
  sorted_findings | awk -F'\t' -v cap="$MAX_PER_CATEGORY" '
    { line[NR] = $0; key[NR] = $1 "|" $2 "|" $3; total[key[NR]]++ }
    END {
      for (i = 1; i <= NR; i++) {
        seen[key[i]]++
        if (seen[key[i]] <= cap) { print line[i]; continue }
        if (seen[key[i]] == cap + 1) {
          split(key[i], k, "|")
          printf "%s\t%s\t%s\t... %d more finding(s) in this category, not shown\t\n", \
                 k[1], k[2], k[3], total[key[i]] - cap
        }
      }
    }'
}

emit_report() {
  local high warn info total sev app categ text rem
  high="$(awk -F'\t' '$1=="HIGH"' "$FINDINGS" | wc -l | tr -d ' ')"
  warn="$(awk -F'\t' '$1=="WARN"' "$FINDINGS" | wc -l | tr -d ' ')"
  info="$(awk -F'\t' '$1=="INFO"' "$FINDINGS" | wc -l | tr -d ' ')"
  total=$((high + warn + info))

  {
    printf '\n'
    printf '========================================================================\n'
    printf ' CRD UPGRADE CHECK — baseline %s\n' "$BASE_REF"
    printf ' Tier 3 backend: --mode=%s%s\n' "$OPT_MODE" \
      "$( [ "$OPT_SKIP_TIER3" -eq 1 ] && printf ' (skipped)' || true )"
    printf '========================================================================\n'
    if [ "$total" -eq 0 ]; then
      printf '\nNo findings.\n\n'
    else
      printf '\nFindings: %s HIGH, %s WARN, %s INFO\n\n' "$high" "$warn" "$info"
      while IFS=$'\t' read -r sev app categ text rem; do
        printf '[%s] %s (%s)\n' "$sev" "$app" "$categ"
        printf '      %s\n' "$text"
        [ -n "$rem" ] && printf '      -> %s\n' "$rem"
        printf '\n'
      done < <(capped_findings)
    fi

    if [ -s "$SKIPS" ]; then
      printf 'SKIPPED\n'
      LC_ALL=C sort -u "$SKIPS" | sed 's/^/  - /'
      printf '\n'
    fi

    printf 'NOT VERIFIED BY THIS CHECK\n'
    printf '  - Validating admission webhooks. kube-prometheus-stack ships a\n'
    printf '    prometheus-operator admission webhook that PromQL-parses PrometheusRule\n'
    printf '    expressions and rejects invalid ones; nothing here models it. A rule that\n'
    printf '    passes this check can still be rejected by the live cluster.\n'
    if [ "$OPT_MODE" != "apiserver" ] || [ "$OPT_SKIP_TIER3" -eq 1 ]; then
      printf '  - CEL rules (x-kubernetes-validations) and server-side defaulting. JSON\n'
      printf '    Schema validation cannot evaluate CEL. Re-run with --mode=apiserver.\n'
    fi
    if [ "$OPT_LIVE" -eq 0 ]; then
      printf '  - CRs that exist only in the live cluster (created by an operator, by hand,\n'
      printf '    or left behind by a removed app), and live status.storedVersions.\n'
      printf '    Re-run with --live against the cluster.\n'
    elif [ "$LIVE_OK" -eq 0 ]; then
      printf '  - Live CR validation and status.storedVersions were requested but skipped\n'
      printf '    (%s).\n' "$LIVE_REASON"
    fi
    printf '  - Operator/CRD version compatibility. The operator image is pinned by a\n'
    printf '    separate HelmRelease and bumped by a separate Renovate PR; a CRD chart can\n'
    printf '    be schema-valid and still be ahead of (or behind) the running operator.\n'
    printf '  - Upgrade mechanics: conversion webhooks, storage migration of existing\n'
    printf '    objects, and Helm/Flux field-ownership conflicts are all out of scope.\n'
    if [ -s "$NOTES" ]; then
      LC_ALL=C sort -u "$NOTES" | sed 's/^/  - /'
    fi
    printf '\n'
    if [ "$high" -gt 0 ]; then
      printf 'RESULT: %s HIGH finding(s) — do not merge without reading them.\n' "$high"
    else
      printf 'RESULT: no HIGH findings. Read the NOT VERIFIED list above before merging.\n'
    fi
    printf '\n'
  } | tee "$TMP/report.txt"

  [ -n "$OPT_MARKDOWN" ] && emit_markdown "$high" "$warn" "$info" "$total"

  [ "$high" -gt 0 ] && return 1
  return 0
}

# Backticks below are Markdown code spans, not command substitution.
# shellcheck disable=SC2016
emit_markdown() { # high warn info total
  local high="$1" warn="$2" info="$3" total="$4" sev app categ text rem
  {
    printf '## CRD Upgrade Check\n\n'
    printf '_Report-only: this check never blocks a merge. Baseline `%s`, Tier 3 backend `--mode=%s`._\n\n' \
      "$BASE_REF" "$OPT_MODE"
    if [ "$total" -eq 0 ]; then
      printf 'No findings.\n\n'
    else
      printf '**%s HIGH · %s WARN · %s INFO**\n\n' "$high" "$warn" "$info"
      printf '| Severity | App | Category | Finding | Remediation |\n'
      printf '| --- | --- | --- | --- | --- |\n'
      while IFS=$'\t' read -r sev app categ text rem; do
        printf '| %s | `%s` | `%s` | %s | %s |\n' "$sev" "$app" "$categ" \
          "$(printf '%s' "$text" | sed 's/|/\\|/g')" \
          "$(printf '%s' "$rem"  | sed 's/|/\\|/g')"
      done < <(capped_findings)
      printf '\n'
    fi
    if [ -s "$SKIPS" ]; then
      printf '### Skipped\n\n'
      LC_ALL=C sort -u "$SKIPS" | sed 's/^/- /'
      printf '\n'
    fi
    printf '### NOT VERIFIED BY THIS CHECK\n\n'
    printf -- '- **Validating admission webhooks.** kube-prometheus-stack ships a prometheus-operator admission webhook that PromQL-parses `PrometheusRule` expressions and rejects invalid ones; nothing here models it.\n'
    if [ "$OPT_MODE" != "apiserver" ] || [ "$OPT_SKIP_TIER3" -eq 1 ]; then
      printf -- '- **CEL rules (`x-kubernetes-validations`) and server-side defaulting** are not evaluated in `--mode=schema`.\n'
    fi
    if [ "$OPT_LIVE" -eq 0 ]; then
      printf -- '- **CRs that exist only in the live cluster**, and live `status.storedVersions`, were not checked (`--live` not used; CI has no kubeconfig).\n'
    elif [ "$LIVE_OK" -eq 0 ]; then
      printf -- '- **Live checks were requested but skipped** (%s).\n' "$LIVE_REASON"
    fi
    printf -- '- **Operator/CRD version compatibility.** The operator image is pinned by a separate HelmRelease and bumped by a separate Renovate PR.\n'
    printf -- '- **Upgrade mechanics**: conversion webhooks, storage migration of existing objects, and Helm/Flux field-ownership conflicts are out of scope.\n'
    if [ -s "$NOTES" ]; then
      LC_ALL=C sort -u "$NOTES" | sed 's/^/- /'
    fi
    printf '\n'
  } >"$OPT_MARKDOWN"
}

# ---------------------------------------------------------------------------
# Tier 1 — CRD object safety
# ---------------------------------------------------------------------------

# $c is a jq variable, not a shell one.
# shellcheck disable=SC2016
CRD_TSV='. as $c | $c.spec.versions[]
  | [$c.metadata.name, $c.spec.group, $c.spec.names.kind, $c.spec.scope,
     .name, (.served|tostring), (.storage|tostring)] | @tsv'

tier1_object_safety() { # app old_ndjson new_ndjson compare(0|1)
  local app="$1" old="$2" new="$3" compare="$4"
  local facts_old="$TMP/t1-old.tsv" facts_new="$TMP/t1-new.tsv"
  local crd o_scope n_scope o_kind n_kind ver served n_line n_served o_storage n_storage stored sv

  jq -r "$CRD_TSV" "$old" >"$facts_old"
  jq -r "$CRD_TSV" "$new" >"$facts_new"

  if [ "$compare" -eq 1 ]; then
    # 1A — CRDs that disappeared / appeared.
    while IFS= read -r crd; do
      [ -n "$crd" ] || continue
      finding HIGH "$app" "tier1a/crd-removed" \
        "CRD ${crd} exists in the old chart and is gone from the new one" \
        "Flux prunes it on apply, taking every ${crd} object with it. Confirm the CRD moved to another chart, or pin the old version."
    done < <(comm -23 <(cut -f1 "$facts_old" | LC_ALL=C sort -u) \
                      <(cut -f1 "$facts_new" | LC_ALL=C sort -u))

    while IFS= read -r crd; do
      [ -n "$crd" ] || continue
      finding INFO "$app" "tier1a/crd-added" \
        "CRD ${crd} is new in this chart version" \
        "No action needed; noted so the apply's blast radius is visible."
    done < <(comm -13 <(cut -f1 "$facts_old" | LC_ALL=C sort -u) \
                      <(cut -f1 "$facts_new" | LC_ALL=C sort -u))

    # 1B — per-CRD scope / kind / version-list changes.
    while IFS= read -r crd; do
      [ -n "$crd" ] || continue
      o_scope="$(awk -F'\t' -v c="$crd" '$1==c {print $4; exit}' "$facts_old")"
      n_scope="$(awk -F'\t' -v c="$crd" '$1==c {print $4; exit}' "$facts_new")"
      o_kind="$(awk  -F'\t' -v c="$crd" '$1==c {print $3; exit}' "$facts_old")"
      n_kind="$(awk  -F'\t' -v c="$crd" '$1==c {print $3; exit}' "$facts_new")"
      if [ "$o_scope" != "$n_scope" ]; then
        finding HIGH "$app" "tier1b/scope-changed" \
          "CRD ${crd} scope changed ${o_scope} -> ${n_scope}" \
          "The apiserver rejects a scope change on an existing CRD; it must be deleted and recreated, destroying its objects."
      fi
      if [ "$o_kind" != "$n_kind" ]; then
        finding HIGH "$app" "tier1b/kind-changed" \
          "CRD ${crd} names.kind changed ${o_kind} -> ${n_kind}" \
          "Every manifest referencing the old kind stops resolving. Treat as a breaking rename."
      fi

      while IFS=$'\t' read -r ver served; do
        [ -n "$ver" ] || continue
        n_line="$(awk -F'\t' -v c="$crd" -v v="$ver" '$1==c && $5==v {print $6; exit}' "$facts_new")"
        if [ -z "$n_line" ]; then
          finding HIGH "$app" "tier1b/version-removed" \
            "CRD ${crd}: version ${ver} (served=${served}) is gone from the new chart" \
            "Any stored or in-Git object on ${ver} breaks. Migrate objects to a surviving version first, then bump."
        else
          n_served="$n_line"
          if [ "$served" = "true" ] && [ "$n_served" != "true" ]; then
            finding HIGH "$app" "tier1b/version-unserved" \
              "CRD ${crd}: version ${ver} is no longer served (served=${n_served})" \
              "Clients and manifests pinned to ${ver} will 404. Move them to a served version before merging."
          fi
        fi
      done < <(awk -F'\t' -v c="$crd" '$1==c {print $5"\t"$6}' "$facts_old")

      o_storage="$(awk -F'\t' -v c="$crd" '$1==c && $7=="true" {print $5; exit}' "$facts_old")"
      n_storage="$(awk -F'\t' -v c="$crd" '$1==c && $7=="true" {print $5; exit}' "$facts_new")"
      if [ -n "$o_storage" ] && [ -n "$n_storage" ] && [ "$o_storage" != "$n_storage" ]; then
        finding WARN "$app" "tier1b/storage-moved" \
          "CRD ${crd}: storage version moved ${o_storage} -> ${n_storage}" \
          "Existing objects stay on ${o_storage} until rewritten. Plan a storage-version migration before ${o_storage} is ever dropped."
      fi
    done < <(comm -12 <(cut -f1 "$facts_old" | LC_ALL=C sort -u) \
                      <(cut -f1 "$facts_new" | LC_ALL=C sort -u))
  fi

  # 1C — live storedVersions vs the new chart's version list.
  if [ "$LIVE_OK" -eq 1 ]; then
    while IFS= read -r crd; do
      [ -n "$crd" ] || continue
      stored="$(kubectl --request-timeout="$KUBECTL_TIMEOUT" get crd "$crd" \
                  -o jsonpath='{.status.storedVersions}' 2>/dev/null || true)"
      [ -n "$stored" ] || continue
      while IFS= read -r sv; do
        [ -n "$sv" ] || continue
        if ! awk -F'\t' -v c="$crd" -v v="$sv" \
               '$1==c && $5==v {found=1} END {exit !found}' "$facts_new"; then
          finding HIGH "$app" "tier1c/storedversion-dropped" \
            "CRD ${crd}: live status.storedVersions still lists ${sv}, which the new chart no longer declares" \
            "The apiserver rejects the CRD update outright. Rewrite the stored objects onto a surviving version and patch status.storedVersions before bumping."
        fi
      done < <(printf '%s' "$stored" | jq -r '.[]?' 2>/dev/null || true)
    done < <(cut -f1 "$facts_new" | LC_ALL=C sort -u)
  else
    skipped "Tier 1C (live status.storedVersions) — ${LIVE_REASON}"
  fi
}

# ---------------------------------------------------------------------------
# Tier 2 — schema delta
# ---------------------------------------------------------------------------

tier2_schema_delta() { # app old_ndjson new_ndjson
  local app="$1" old="$2" new="$3"
  local crd ver o_schema n_schema sev categ text rem
  local versions=0 changed=0 added_props=0 n before after

  before="$(wc -l <"$FINDINGS" | tr -d ' ')"

  while IFS=$'\t' read -r crd ver; do
    [ -n "$crd" ] || continue
    versions=$((versions + 1))
    o_schema="$(jq -c --arg c "$crd" --arg v "$ver" \
      'select(.metadata.name == $c) | .spec.versions[] | select(.name == $v) | (.schema.openAPIV3Schema // {})' "$old")"
    n_schema="$(jq -c --arg c "$crd" --arg v "$ver" \
      'select(.metadata.name == $c) | .spec.versions[] | select(.name == $v) | (.schema.openAPIV3Schema // {})' "$new")"
    [ -n "$o_schema" ] && [ -n "$n_schema" ] || continue
    [ "$o_schema" = "$n_schema" ] && continue
    changed=$((changed + 1))

    printf '%s' "$o_schema" | jq -c --from-file "$TMP/facts.jq" >"$TMP/facts-old.json"
    printf '%s' "$n_schema" | jq -c --from-file "$TMP/facts.jq" >"$TMP/facts-new.json"

    # Optional fields that were added are not a finding, but the count is the
    # difference between "nothing changed" and "nothing risky changed".
    n="$(jq -n --slurpfile o "$TMP/facts-old.json" --slurpfile n "$TMP/facts-new.json" '
           def idx: INDEX(.kind + " " + .path);
           ($o[0] | idx) as $O | ($n[0] | idx) as $N
           | [ $N | to_entries[] | select(.value.kind == "properties")
               | (.value.values - (($O[.key] // {values: []}).values)) ]
           | add // [] | length' 2>/dev/null || echo 0)"
    added_props=$((added_props + n))

    while IFS=$'\t' read -r sev categ text rem; do
      [ -n "$sev" ] || continue
      finding "$sev" "$app" "$categ" "$text" "$rem"
    done < <(jq -r -n \
               --slurpfile o "$TMP/facts-old.json" \
               --slurpfile n "$TMP/facts-new.json" \
               --arg crd "$crd" --arg ver "$ver" --argjson max "$MAX_ITEMS" \
               --from-file "$TMP/schemadelta.jq")
  done < <(jq -r '. as $c | $c.spec.versions[] | [$c.metadata.name, .name] | @tsv' "$new" \
           | LC_ALL=C sort -u)

  after="$(wc -l <"$FINDINGS" | tr -d ' ')"
  finding INFO "$app" "tier2/summary" \
    "compared ${versions} CRD version(s); ${changed} schema(s) differ; ${added_props} optional field(s) added; $((after - before)) flagged change(s) (new required / narrowed enum / removed property / CEL)" \
    "A zero flagged count means the four risk categories were checked and came back empty — not that the delta went unexamined."
}

# ---------------------------------------------------------------------------
# Tier 3 — CR admission validation
# ---------------------------------------------------------------------------

validate_crs() { # app new_ndjson crs_yaml count source_label
  local app="$1" new="$2" crs_yaml="$3" count="$4" label="$5"
  local errs schemadir

  if [ "$OPT_MODE" = "apiserver" ]; then
    if ! ensure_apiserver; then
      skipped "Tier 3 --mode=apiserver — ${APISERVER_REASON}"
      note "Tier 3 did not run against a real apiserver, so CEL and defaulting were not exercised."
      return 0
    fi
    if ! install_crds_into_apiserver "$new"; then
      finding HIGH "$app" "tier3/crd-install-failed" \
        "a clean apiserver rejected the new chart's CRDs: $(tail -n 3 "$TMP/crd-install.log" | tr '\n\t' '  ' | cut -c1-400)" \
        "Fix the CRD manifests or pin the previous chart version; Flux will hit the same error."
      return 0
    fi
    ensure_namespaces "$crs_yaml"
    # Mirror Flux: server-side apply, not kubectl's client-side default. The
    # client-side path fails on large CRDs with the 262144-byte annotation limit.
    if kubectl --kubeconfig "$APISERVER_KUBECONFIG" --request-timeout="$KUBECTL_TIMEOUT_LONG" \
         apply --server-side --force-conflicts --field-manager=crd-upgrade-check \
         --dry-run=server -f "$crs_yaml" >"$TMP/dryrun.log" 2>&1; then
      finding INFO "$app" "tier3/admission-ok" \
        "${count} CR(s) from the ${label} were admitted by an apiserver running the new CRDs (CEL evaluated)" \
        ""
    else
      errs="$(grep -vi '^warning:' "$TMP/dryrun.log" | grep -i 'error' | head -n "$MAX_ITEMS" \
              | tr '\n\t' '  ' | cut -c1-800 || true)"
      [ -n "$errs" ] || errs="$(tail -n 5 "$TMP/dryrun.log" | tr '\n\t' '  ' | cut -c1-800)"
      finding HIGH "$app" "tier3/admission-rejected" \
        "apiserver dry-run rejected CR(s) from the ${label}: ${errs}" \
        "Two different outcomes hide behind this. Type errors, missing required fields and CEL violations fail Flux's apply too — fix them in Git or hold the bump. Unknown/removed fields do NOT fail: kubectl validates strictly, Flux does not, so the apiserver prunes them and the setting is lost silently. Read the messages to tell which you have."
    fi
    return 0
  fi

  # --mode=schema
  if ! have kubeconform; then
    skipped "Tier 3 --mode=schema — kubeconform not found (pinned in .mise.toml)"
    note "No CR validation ran: kubeconform is unavailable."
    return 0
  fi
  schemadir="$TMP/schemas"
  rm -rf "$schemadir"
  build_json_schemas "$new" "$schemadir"
  if kubeconform \
       -schema-location "${schemadir}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
       -summary -output text "$crs_yaml" >"$TMP/kubeconform.log" 2>&1; then
    finding INFO "$app" "tier3/schema-ok" \
      "${count} CR(s) from the ${label} validate against the new chart's JSON Schemas" \
      "Schema-only: CEL rules and admission webhooks were not evaluated."
  else
    errs="$(grep -v '^Summary:' "$TMP/kubeconform.log" | head -n "$MAX_ITEMS" \
            | tr '\n\t' '  ' | cut -c1-800 || true)"
    finding HIGH "$app" "tier3/schema-invalid" \
      "CR(s) from the ${label} do not validate against the new chart's schemas: ${errs}" \
      "Type errors and missing required fields fail Flux's apply. Unknown/removed fields do not — Flux applies without strict field validation, so the apiserver prunes them and the setting is lost silently; that is data loss, not a blocked merge. Re-run with --mode=apiserver to also evaluate CEL."
  fi
}

tier3_admission() { # app new_ndjson
  local app="$1" new="$2"
  local groups kinds crs="$TMP/crs.ndjson" crs_yaml="$TMP/crs.yaml" count k g live_count

  groups="$(jq -r '.spec.group'      "$new" | LC_ALL=C sort -u | jq -R . | jq -s -c .)"
  kinds="$(jq  -r '.spec.names.kind' "$new" | LC_ALL=C sort -u | jq -R . | jq -s -c .)"

  yq -o=json -I=0 '.' "$RENDERED" 2>/dev/null \
    | jq -c --argjson groups "$groups" --argjson kinds "$kinds" '
        select(type == "object" and (.kind? != null) and (.apiVersion? != null))
        | select((.apiVersion | tostring | split("/") | .[0]) as $g | $groups | index($g))
        | select(.kind as $k | $kinds | index($k))' >"$crs" || true

  count="$(wc -l <"$crs" | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    grouplist="$(printf '%s' "$groups" | jq -r 'join(", ")')"
    finding INFO "$app" "tier3/no-crs" \
      "the rendered cluster manifest contains no CRs for group(s) ${grouplist}" \
      "Nothing to validate from Git; live CRs may still exist (see --live)."
  else
    yq -p=json -o=yaml '.' "$crs" >"$crs_yaml"
    validate_crs "$app" "$new" "$crs_yaml" "$count" "rendered manifest"
  fi

  if [ "$OPT_LIVE" -eq 1 ] && [ "$LIVE_OK" -eq 1 ]; then
    : >"$TMP/live.ndjson"
    while IFS=$'\t' read -r k g; do
      [ -n "$k" ] || continue
      kubectl --request-timeout="$KUBECTL_TIMEOUT_LONG" get "${k}.${g}" -A -o json 2>/dev/null \
        | jq -c '.items[]?
            | del(.status, .metadata.managedFields, .metadata.creationTimestamp,
                  .metadata.resourceVersion, .metadata.uid, .metadata.generation,
                  .metadata.selfLink, .metadata.ownerReferences)' \
        >>"$TMP/live.ndjson" || true
    done < <(jq -r '[.spec.names.kind, .spec.group] | @tsv' "$new")
    if [ -s "$TMP/live.ndjson" ]; then
      yq -p=json -o=yaml '.' "$TMP/live.ndjson" >"$TMP/live-crs.yaml"
      live_count="$(wc -l <"$TMP/live.ndjson" | tr -d ' ')"
      validate_crs "$app" "$new" "$TMP/live-crs.yaml" "$live_count" "live cluster"
    else
      finding INFO "$app" "tier3/no-live-crs" "no live CRs found for this app's kinds" ""
    fi
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

msg "== crd-upgrade-check =="
msg "repo:     ${REPO_ROOT}"
msg "baseline: ${BASE_REF}"
msg "mode:     ${OPT_MODE}"

TARGETS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  TARGETS[${#TARGETS[@]}]="$line"
done < <(discover_targets)

if [ "${#TARGETS[@]}" -eq 0 ]; then
  msg "no helmrelease-crds.yaml found under kubernetes/ — nothing to check"
  emit_report || true
  exit 0
fi
msg "targets:  ${#TARGETS[@]}"

if [ "$OPT_LIVE" -eq 1 ]; then
  probe_live_cluster || true
fi
msg "live:     ${LIVE_REASON}"

if [ "$OPT_SKIP_TIER3" -eq 1 ]; then
  skipped "Tier 3 (CR admission validation) — --skip-tier3"
elif ! build_rendered_manifest; then
  skipped "Tier 3 (CR admission validation) — could not render the cluster manifest: ${RENDER_REASON}"
  note "No CRs were validated at all: the rendered cluster manifest could not be built."
  OPT_SKIP_TIER3=1
fi

for target in "${TARGETS[@]}"; do
  rel="${target#"$REPO_ROOT"/}"
  app_dir="$(dirname "$target")"
  app="$(basename "$(dirname "$(dirname "$app_dir")")")/$(basename "$(dirname "$app_dir")")"
  msg ""
  msg "-- ${app} (${rel})"

  # Both files are per-app but live at fixed paths, so clear them between
  # iterations: without this, an app whose own render fails could silently be
  # diffed against the previous app's CRDs. Every failure path below also sets
  # compare=0, but that invariant should not be the only thing preventing it.
  rm -f "$TMP/crds-old.ndjson" "$TMP/crds-new.ndjson"

  hr_new="$(yq -o=json -I=0 'select(.kind == "HelmRelease")' "$target" 2>/dev/null || true)"
  if [ -z "$hr_new" ]; then
    finding HIGH "$app" "parse" "no HelmRelease document in ${rel}" \
      "Fix the file; Flux cannot reconcile it either."
    continue
  fi

  hr_old="$(git -C "$REPO_ROOT" show "${BASE_REF}:${rel}" 2>/dev/null \
            | yq -o=json -I=0 'select(.kind == "HelmRelease")' 2>/dev/null || true)"
  compare=1
  if [ -z "$hr_old" ]; then
    finding INFO "$app" "baseline" \
      "${rel} does not exist at ${BASE_REF} — this is a new CRD HelmRelease" \
      "Tier 1A/1B and Tier 2 need a baseline; only Tier 1C and Tier 3 ran for this app."
    compare=0
  fi

  if ! src_new="$(resolve_chart_source "$app_dir" "$hr_new" "" "$app")"; then
    finding HIGH "$app" "source" "could not resolve the chart source for the new version" \
      "See the stderr message above; the check refuses to guess rather than misparse."
    continue
  fi
  IFS=$'\t' read -r chart_new url_new ver_new <<<"$src_new"
  extract_values "$hr_new" "$TMP/values-new.yaml"
  if printf '%s' "$hr_new" | jq -e '(.spec.valuesFrom? // []) | length > 0' >/dev/null 2>&1; then
    note "${app}: spec.valuesFrom is not resolved here, so CRD selection driven by a ConfigMap/Secret is not reflected."
  fi

  msg "   new: ${chart_new} ${ver_new}"
  if ! render_crds "$chart_new" "$url_new" "$ver_new" "$TMP/values-new.yaml" "$TMP/crds-new.ndjson"; then
    finding HIGH "$app" "render" "could not render CRDs from ${chart_new} ${ver_new}" \
      "Check the chart name, version and repository in ${rel}."
    continue
  fi

  if [ "$compare" -eq 1 ]; then
    if ! src_old="$(resolve_chart_source "$app_dir" "$hr_old" "$BASE_REF" "$app")"; then
      finding HIGH "$app" "source" "could not resolve the chart source at ${BASE_REF}" \
        "See the stderr message above; the check refuses to guess rather than misparse."
      compare=0
    else
      IFS=$'\t' read -r chart_old url_old ver_old <<<"$src_old"
      extract_values "$hr_old" "$TMP/values-old.yaml"
      msg "   old: ${chart_old} ${ver_old} (from ${BASE_REF})"
      if [ "$ver_old" = "$ver_new" ] && [ "$chart_old" = "$chart_new" ]; then
        finding INFO "$app" "baseline" "chart version unchanged at ${ver_new}" \
          "Tier 1A/1B and Tier 2 have nothing to compare; Tier 1C and Tier 3 still ran."
        compare=0
      elif ! render_crds "$chart_old" "$url_old" "$ver_old" "$TMP/values-old.yaml" "$TMP/crds-old.ndjson"; then
        finding WARN "$app" "render" \
          "could not render CRDs from the baseline ${chart_old} ${ver_old}" \
          "Tier 1A/1B and Tier 2 were skipped for this app; Tier 3 still ran."
        compare=0
      fi
    fi
  fi

  if [ "$compare" -eq 1 ]; then
    tier1_object_safety "$app" "$TMP/crds-old.ndjson" "$TMP/crds-new.ndjson" 1
    tier2_schema_delta  "$app" "$TMP/crds-old.ndjson" "$TMP/crds-new.ndjson"
  else
    # 1C is meaningful on its own even without a baseline.
    tier1_object_safety "$app" "$TMP/crds-new.ndjson" "$TMP/crds-new.ndjson" 0
  fi

  if [ "$OPT_SKIP_TIER3" -eq 0 ]; then
    tier3_admission "$app" "$TMP/crds-new.ndjson"
  fi
done

emit_report
