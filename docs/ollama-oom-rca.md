# Ollama OOMKills and node saturation (2026-11-06)

CPU-only Ollama (`default/ollama`) serving n8n's Readwise feed classification. Alerts: `PodMemoryRestartedWhileHot`
(critical, `ollama-*`), plus `HostHighCpuUsage`, `NodeSystemSaturation` and `NodeCPUHighUsage` on cmp-01 (192.168.25.21).

## Evidence

- `app` container OOMKilled 5 times in ~6h (limit 5Gi). `container_memory_working_set_bytes` climbed in ~420-500Mi steps
  from 3.3Gi (model + 4k context) to the limit, then reset on restart. Each step lines up with llama-server logging
  `prompt_save: saving prompt ... total state size = 513 MiB`.
- Requests from n8n (10.42.3.119) took 17m to 1h5m each; two hit the 1h timeout (500). `prompt eval 0.25 tok/s`,
  `eval 1.1 tok/s`, 3123 generated tokens for one item.
- `ollama ps`: `qwen3:4b` is `Qwen3 4B Thinking 2507` (the Ollama `qwen3:4b` tag is the thinking build), 100% CPU.
- Ollama `app` container used ~2.3 CPUs of cmp-01's 3 with a 500m request and no limit.

## Root cause

1. **Thinking model on CPU.** Every classification generated thousands of reasoning tokens at ~1 tok/s. Runtime per item
   was tens of minutes. `--context-shift` (Ollama default) lets a 4k context generate indefinitely.
2. **n8n queues many concurrent requests** against `OLLAMA_NUM_PARALLEL=1`, so most of each request's wall time was
   queue wait; the CPU never idled.
3. **llama-server host prompt cache.** Each finished prompt state (~500Mi at 3.6k tokens) is kept in RAM up to a default
   `cache-ram` of 8Gi, far above the pod's 5Gi limit. Memory grew until OOMKill. This is not a leak in the model.
4. **Unbounded CPU** starved cmp-01 (3 CPUs, also runs other workloads) and raised node saturation alerts.

A larger memory limit would only have delayed the kill. A second instance would have doubled the CPU contention: the
bottleneck is CPU, not request concurrency, so do not scale out on this cluster.

## Fix (helmrelease.yaml)

- Model `qwen3:4b-instruct-2507-q4_K_M` (non-thinking). **n8n's Ollama node must use this exact model name.**
  The old `qwen3:4b` blob stays on the PVC (8Gi); `ollama rm qwen3:4b` reclaims ~2.5Gi when convenient.
- `LLAMA_ARG_CACHE_RAM=0` disables the host prompt cache; `LLAMA_ARG_THREADS=2` matches the CPU limit.
- CPU request 1000m, limit 2. Deliberate exception to "no CPU limits": see comment in the manifest.
- Memory limit unchanged (5Gi) pending data: expect a flat ~3.3Gi. Revisit with
  `max_over_time(container_memory_working_set_bytes{pod=~"ollama-.*"}[7d])` once a batch has run.

## Verify after rollout

Env passthrough is not proof the settings work; check effective behaviour:

- The runner argv Ollama logs at start (`starting llama-server cmd=...`, 2026-11-06 13:19) carried no `--threads` and
  no `--cache-ram`, so the `LLAMA_ARG_*` env vars are not overridden by a flag. Re-read that line after rollout: if a
  `-t`/`--cache-ram` appears, the env var loses. Fallbacks: `num_thread` in request options or a Modelfile (threads),
  `OLLAMA_NUM_PARALLEL` / smaller context (cache).
- `kubectl -n default logs deploy/ollama -c app | grep -c prompt_save` stays 0 across a batch.
- `container_memory_working_set_bytes{pod=~"ollama-.*",container="app"}` stays flat (~3.3Gi) across a batch.
- `rate(container_cpu_usage_seconds_total{pod=~"ollama-.*",container="app"}[5m])` sits at or under 2, with
  `container_cpu_cfs_throttled_periods_total` not climbing hard.
- Item latency is seconds, not minutes.

## More than one replica?

Not now, but not ruled out. Scrutiny on 2026-11-06:

- Workload is batch, latency-insensitive and CPU-bound, so throughput scales with cores: two pods on separate nodes
  double items/hour, if each has its own cores. Both pods must not share a node (they would fight for the same ~2 CPUs).
- Capacity today (allocatable / requested CPU): cmp-01 2.95 / 1.68, cmp-02 2.95 / 1.67, cmp-05 3.95 / 2.18. With
  the old thinking model and a 1500m request nothing fit but cmp-01. At 1000m, cmp-01 and cmp-02 take one each
  (~74% requested, under the 85% alert); cmp-05 was added to the node affinity (user call: inference does no steady disk I/O, and cmp-05 has the most free CPU and RAM); its slow
  system disk only hurts the one-time image pull and model load. Memory is the tighter limit: MemAvailable was 1.6Gi on cmp-01 (with the
  leaking pod at 5Gi) and 3.0Gi on cmp-02 at observation time, vs ~3.3Gi per pod.
- Each pod needs its own model volume (RWO), so this is a StatefulSet with `volumeClaimTemplates` or a second
  release, not `replicas: 2` on the current Deployment. n8n reaches them through one Service; kube-proxy-style
  balancing is per-connection, so n8n keep-alive can pin to one pod. Check actual spread before trusting it.
- Decide with data, not before: first measure single-pod items/hour with the instruct model against the real backlog
  and steady-state arrival rate. If one pod clears the backlog inside the schedule, a second adds node pressure for
  nothing. Tracked as `docs/revisit-register.md` #20.

## n8n follow-ups (not in Git; the workflow lives in n8n's DB)

- Process one item at a time (SplitInBatches size 1, or concurrency 1) so requests do not queue for an hour.
- Set `num_predict` (e.g. 256) and `think: false` on the request, and a client timeout of a few minutes.
- Keep `format`/JSON output short; classification labels do not need prose.
