#!/usr/bin/env bash
# portforward.sh
#
# Shared kubectl port-forward-and-wait-for-port helper.
#
# Source this file, then call:
#   pf_start <namespace> <service> <remote-port> [<probe-path>]
#
# Sets globals PF_PID and PORT, and registers an EXIT trap that kills the
# forward and removes its log file. Requires the caller to already define a
# `die()` function (every script in scripts/ that ports-forward already does)
# — this file intentionally has no error-reporting of its own.
#
# probe-path, if given, is an HTTP path (e.g. /-/healthy) polled with a
# throwaway request after the port-forward's local listener comes up. This
# guards against the listener being bound but the tunnel not yet reaching a
# live pod — most likely right after the target pod restarts or reschedules.
# Best effort only: it proceeds regardless of whether the probe ever
# succeeds, since the real request that follows is the actual arbiter.

PF_PID=""
PORT=""
PF_LOG=""

pf_start() {
  local namespace="$1" service="$2" remote_port="$3" probe_path="${4:-}"

  PF_LOG="$(mktemp)"
  kubectl -n "$namespace" port-forward "svc/${service}" ":${remote_port}" >"$PF_LOG" 2>&1 &
  PF_PID=$!
  trap 'kill "$PF_PID" 2>/dev/null || true; rm -f "$PF_LOG"' EXIT

  for _ in $(seq 1 50); do
    PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$PF_LOG" | head -1)"
    [ -n "$PORT" ] && break
    sleep 0.2
  done
  [ -n "$PORT" ] || die "port-forward to svc/${service} -n ${namespace} never came up: $(cat "$PF_LOG")"

  if [ -n "$probe_path" ]; then
    for _ in $(seq 1 50); do
      curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}${probe_path}" && break || true
      sleep 0.2
    done
  fi
}
