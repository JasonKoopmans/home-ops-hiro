#!/usr/bin/env bash
# Render minio chart 5.4.0 with this repo's real HelmRelease values (both instances) and
# optionally with an image override, so the Deployment's needs from the image can be read off.
# usage: 00-render-chart.sh [image-repo image-tag mc-repo mc-tag]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
command -v helm >/dev/null || { echo "helm not found"; exit 1; }
SETS=()
if [ $# -ge 4 ]; then
  SETS=(--set "image.repository=$1" --set "image.tag=$2" --set "mcImage.repository=$3" --set "mcImage.tag=$4")
fi
for app in minio recording-annotator-minio; do
  git -C "$REPO_ROOT" show "$MANIFEST_REF:kubernetes/apps/storage/$app/app/helmrelease.yaml" |
    python3 -I -c 'import sys,yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin)["spec"]["values"]))' >"$SQ_OUT/values-$app.yaml"
  helm template "$app" minio --repo https://charts.min.io/ --version 5.4.0 -n storage \
    -f "$SQ_OUT/values-$app.yaml" ${SETS[@]+"${SETS[@]}"} >"$SQ_OUT/rendered-$app.yaml"
  echo "rendered $SQ_OUT/rendered-$app.yaml ($(grep -c '^kind:' "$SQ_OUT/rendered-$app.yaml") objects)"
done
