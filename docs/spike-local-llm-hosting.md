# Spike: hosting local LLMs

> **Status:** design. CPU-only Ollama runs in `default` (`kubernetes/apps/default/ollama/`) for n8n's feed classification. Whether
> to host a larger model for the Hermes agent is open and waits on hardware this cluster does not have. The colibri figures below
> come from its own README and API docs and were never run here.

## Question

Can the cluster, or the Proxmox hosts under it, run a local model well enough to (a) classify feed items for n8n in bulk and
(b) act as the brain of the Hermes agent (`kubernetes/apps/default/hermes-ai-agent/`)? The prompt was
[colibri](https://github.com/JustVugg/colibri), a C inference engine that keeps dense weights in RAM and streams the routed experts
of a large MoE model from disk. Theme 1 of [homelab-goals](homelab-goals.md) is the reason to ask.

## What we found (2026-10-30)

**Hardware is the limit, not software.** Proxmox-reported memory use that day, no GPU anywhere:

| Host | Cores | RAM | Used | Free |
|---|---|---|---|---|
| vm03 | 4 | 31.2 GB | 65.8% | ~10.7 GB |
| vm01 | 6 | 31.2 GB | 77.9% | ~6.9 GB |
| vm04 | 4 | 15.5 GB | 82.2% | ~2.7 GB |
| vm02 | 6 | 15.5 GB | 84.3% | ~2.4 GB |
| vm05 | 4 | 15.4 GB | 84.7% | ~2.4 GB |
| vm07 | 4 | 7.7 GB | 90.4% | ~0.7 GB |

No host had 16 GB free. The Kubernetes nodes are ~11.8 Gi VMs with 2 to 4 CPUs and thin request headroom ([gotchas-cluster](gotchas-cluster.md)).
This is a snapshot: re-read `get_nodes` before relying on it.

**colibri, as documented.** Apache-2.0, OpenAI-style and Anthropic-style endpoints, tool calling on most engines, a ~115 MB slim
image. Its Docker docs call under 16 GB RAM "No" and ask for 32 GB and a fast SSD. Its own CPU numbers: ~6 to 10 tok/s for
Qwen3.6-35B-A3B on a Ryzen 7 CPU or iGPU, ~1.2 tok/s for DeepSeek V4 Flash on a Ryzen 9 CPU. It warns that agent clients send
10 to 20k-token system prompts, which is slow to prefill on CPU. No GGUF loading is mentioned. Fresh and fast-moving; expect breaking changes.

| Server | Fit here |
|---|---|
| llama.cpp server / Ollama | Broadest model support (GGUF), the most mature tool calling, runs on CPU. **Chosen.** |
| vLLM | Best throughput, but needs a GPU. |
| colibri | Worth a trial for big MoE models on a box with 32 GB+ RAM and NVMe; not on a cluster node (weights stream from disk, and Longhorn is the wrong disk). |

## Decision

- **Bulk classification: yes, in the cluster.** The first workload is the Lifehacker branch of the "Readwise Flows" n8n workflow
  (about 12 to 24 items a day, four labels on a short summary). That is prefill-light and latency-insensitive, so a small model on
  CPU is enough. Hosted Sonnet was doing it; a rough guess is cents a month, so the case is privacy, learning and a hybrid setup, not savings (unmeasured).
- **A dedicated worker node was considered and deferred.** It would be a VM carved from vm03, the only host with room, and a
  pod on an existing node was enough to measure first.
- **The Hermes brain stays on a hosted model for now.** An agent loop needs a 20 to 35B model with reliable tool calls and long
  prompts. That is not viable on these CPUs.
- **If that changes,** host it off-cluster (a Mac with Apple silicon, or a mini-PC with 32 to 64 GB and NVMe) as an
  OpenAI-compatible endpoint, reached from the cluster by an `ExternalName` Service plus a base-URL setting in Hermes. How Hermes
  takes its model settings was not checked here; read its manifests first.
- A hosted fallback for Hermes was left undecided.

## What happened next

The original plan picked the `qwen3:4b` tag, which is the **thinking** build, with memory and CPU values flagged as unmeasured
guesses. Within a week it OOMKilled and saturated its node: [ollama-oom-rca](ollama-oom-rca.md). The fix was the instruct build
and bounded memory and CPU. Two lessons carry over to any model added later: check what a tag really is (`ollama ps`, the model
card) before sizing for it, and treat unmeasured limits as a short-lived guess ([revisit-register](revisit-register.md) #20).

## Revisit when

- A Mac or mini-PC with 32 GB or more is available as an inference host. Then re-test a 20 to 35B MoE (with colibri and with
  llama.cpp) and decide on the Hermes brain.
- Classification expands from one site to every feed item, or embeddings and RAG are added. Volume then changes the case for a
  dedicated worker node.
- A Proxmox host gains 16 GB or more of free RAM, or a GPU.
