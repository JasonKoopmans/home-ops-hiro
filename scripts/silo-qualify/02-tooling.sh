#!/usr/bin/env bash
# Which userland tools exist in each candidate image, and which external commands the repo's
# 7 mc scripts + the chart post-job actually need (computed from the committed manifests).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
R="$SQ_OUT/02-tooling.txt"; : >"$R"
for img in "$SILO_IMG" "$MC_IMG" "$FALLBACK_IMG"; do
  echo "## $img  ($(digest_of "$img"))" | tee -a "$R"
  docker run --rm --entrypoint /bin/sh "$img" -c '
    ls -l /bin/sh | cut -c1-80
    for t in sh bash cat sleep expr mc mcli curl grep sed awk wget tr; do
      p=$(command -v $t 2>/dev/null) && echo "  $t: $p" || echo "  $t: MISSING"
    done
    echo "  HOME=$HOME MC_CONFIG_DIR=${MC_CONFIG_DIR:-<unset>} uid=$(id -u)"' 2>&1 | tee -a "$R"
done
echo "## external commands used by the repo scripts (word-initial tokens that are not shell builtins/keywords)" | tee -a "$R"
for f in kubernetes/apps/storage/minio/app/{thanos-user-bootstrap-job,loki-user-bootstrap-job,bucket-bootstrap-job,bucket-quota-bootstrap-job,bucket-lifecycle-bootstrap-job}.yaml \
         kubernetes/apps/storage/recording-annotator-minio/app/{recording-annotator-user-bootstrap-job,recording-annotator-mirror-cronjob}.yaml; do
  cmds=$(extract_script "$f" | grep -vE '^\s*#' | grep -oE '(^|[;&|(]|then |do |! |until |if )\s*[a-z][a-z-]*' | sed -E 's/^[^a-z]*//; s/^(then|do|if|until) //' | sort -u | tr '\n' ' ')
  echo "  $(basename "$f"): $cmds" | tee -a "$R"
done
