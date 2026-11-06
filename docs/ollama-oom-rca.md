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
- CPU request 1500m, limit 2. Deliberate exception to "no CPU limits": see comment in the manifest.
- Memory limit unchanged (5Gi) pending data: expect a flat ~3.3Gi. Revisit with
  `max_over_time(container_memory_working_set_bytes{pod=~"ollama-.*"}[7d])` once a batch has run.

## Verify after rollout

- `kubectl -n default exec deploy/ollama -c app -- sh -c 'tr "\0" "\n" < /proc/$(pgrep -f llama-server | head -1)/environ | grep LLAMA_ARG'`
  must show both vars. If absent, Ollama does not forward env to the runner: use another mechanism, do not assume.
- Memory flat across a batch; no `prompt_save` lines in the log; item latency seconds, not minutes.

## n8n follow-ups (not in Git; the workflow lives in n8n's DB)

- Process one item at a time (SplitInBatches size 1, or concurrency 1) so requests do not queue for an hour.
- Set `num_predict` (e.g. 256) and `think: false` on the request, and a client timeout of a few minutes.
- Keep `format`/JSON output short; classification labels do not need prose.
