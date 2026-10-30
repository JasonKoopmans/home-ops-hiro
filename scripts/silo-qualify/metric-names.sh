#!/usr/bin/env bash
# Print every distinct minio_* metric name referenced by the repo's alert rules, dashboard and probes.
# usage: metric-names.sh   (reads the working tree, not a git ref)
set -euo pipefail
cd "$(dirname "$0")/../.."
d=kubernetes/apps/monitoring/kube-prometheus-stack/app
grep -ohE 'minio_[a-z0-9_]+' "$d/prometheusrule-minio.yaml" "$d/grafana-dashboard-minio.yaml" "$d/prometheusrule-recording-annotator.yaml" | sort -u
