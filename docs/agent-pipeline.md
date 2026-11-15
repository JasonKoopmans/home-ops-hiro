# Agent pipeline (`agents` namespace)

Claude Code agents that take a GitHub issue labelled `ai-ready` through plan, implementation, independent review and (optionally)
merge, one bounded step per CronJob tick. The design (four-stage pod, label state machine, trust model, engine interface, images)
is in the [agent-pipeline repo README](https://github.com/JasonKoopmans/agent-pipeline); this doc covers only what lives in this
cluster: where it is deployed, its secrets, how to run and read a step, and what broke during the pilot.

## What runs here

| Path | Holds |
|---|---|
| `kubernetes/apps/agents/agent-shared/` | Secrets shared by every target repo: `agent-claude-oauth` (the Claude subscription token) and one `agent-app-<role>` per role (GitHub App id + private key) |
| `kubernetes/apps/agents/agent-<repo>/` | One HelmRelease of the `agent-pipeline` chart per target repo. The pilot is `agent-eshop` (target `JasonKoopmans/eShopOnWeb`, base branch `ai-staging`) |

The HelmRelease values are the **trusted** side of the pipeline: which roles run, the review cap, merge mode, the test gate, images,
egress and `buildEnv`. The target repo cannot change them. Each enabled role renders one CronJob (`agent-eshop-<role>`) and one
egress `CiliumNetworkPolicy`. All CronJobs are `suspend: true` until the pipeline should run on its own.

## Secrets and their rotation

Values never go through chat or logs; every file is a `*.sops.yaml` encrypted with the repo's age key.

| Secret | Created with | Expires | Notes |
|---|---|---|---|
| `agent-app-<role>` | `scripts/provision_apps.py` in the agent-pipeline repo (GitHub App manifest flow, one browser click per App, then Install on the target repo) | Never (the pods mint 1-hour installation tokens from the key) | Apps are per role, not per repo: install the existing App on a new target repo. Run the script from this repo's root with `--out kubernetes/apps/agents/agent-shared/app`; it refuses to run unless the output dir is under a `.sops.yaml` |
| `agent-claude-oauth` | `claude setup-token` on your own machine | One year (current token: about 2027-10-19, [revisit-register](revisit-register.md) #22) | See the truncation trap below |

**`claude setup-token` output wraps in a narrow terminal.** Copying one line gave a 79-character token; Claude then answered every
session with `401 OAuth access token is invalid`. A full token is about 108 characters. Before encrypting a new one, test it:

```bash
read -rs "TOKEN?Paste the setup-token: " && echo "length ${#TOKEN}" && CLAUDE_CODE_OAUTH_TOKEN=$TOKEN claude -p 'Reply with pong.' --output-format json --max-turns 1 | python3 -c 'import sys,json;d=json.load(sys.stdin);print("VALID" if not d.get("is_error") else "INVALID: "+str(d.get("result")))'
```

The shape of a deployed token can be checked without printing it:
`t=$(kubectl -n agents get secret agent-claude-oauth -o jsonpath='{.data.CLAUDE_CODE_OAUTH_TOKEN}' | base64 -d); echo ${#t}; unset t`.

## Running one step by hand

With the CronJobs suspended, a step runs only when started:

```bash
kubectl -n agents create job --from=cronjob/agent-eshop-planner planner-1
```

This creates a Job outside Flux's inventory, so it does not conflict with GitOps; `ttlSecondsAfterFinished` removes it after a day.
Delete a **failed** one once read: the stock `KubeJobFailed` rule fires for as long as the failed Job object exists.

A pod runs `prepare`, `agent`, `verify` (init containers) and `publish`. Read them in that order:

```bash
pod=$(kubectl -n agents get pods -l job-name=planner-1 -o name | head -1)
for c in prepare agent verify publish; do echo "== $c"; kubectl -n agents logs $pod -c $c | tail -5; done
```

Each line is JSON with a `run_id`; the same id is in the claim comment on the issue or PR and in the PR body. A run that fails
before `publish` leaves only its claim comment, which the next run reclaims after `staleClaimMinutes` (75).

## Diagnosing a stalled step: probe pods

The egress policy **drops** blocked connections (Cilium does not reject them), so a blocked host makes the client wait for a TCP
timeout instead of failing. Symptoms are a test gate hitting its 30-minute timeout or a restore that crawls. See
[gotchas-cluster](gotchas-cluster.md#cilium-drops-blocked-egress-so-the-client-hangs).

To find the host, run the same command twice in throwaway pods on the same node, one carrying the role's labels (so the role's
egress policy applies) and one without them, and compare times. Copy the security context, `dnsConfig` (`ndots: 1`), image and
env from the role's CronJob; label the policy pod `app.kubernetes.io/name=agent-pipeline,app.kubernetes.io/instance=agent-eshop,agent-pipeline/role=<role>`.
Wait for `Succeeded`, read `kubectl logs`, then delete both (do not rely on `kubectl run -i --rm`, which can lose the output;
see [gotchas-cluster](gotchas-cluster.md)).

## What the pilot hit, and the fix for each

All found during the first runs against eShopOnWeb (2026-10-17 to 10-21). The agent-pipeline version that fixed each is in brackets.

| Symptom | Cause | Fix |
|---|---|---|
| `prepare` timed out minting the App token at `api.github.com` | CoreDNS `autopath` answered the search-suffixed name, so `toFQDNs` never matched | `ndots: 1` on agent pods (0.1.1); `autopath` removed cluster-wide (#853, [gotchas-cluster](gotchas-cluster.md)) |
| Every Claude session ended after one turn, `status: error` | Truncated setup-token (401) | New token (#855); the check above |
| `verify` hit the 30-minute gate timeout | NuGet checks package-signing certificates for revocation over HTTP (OCSP/CRL); egress drops it. Restore: 92 packages in 5 min with the policy, 339 in 22 s without | `NUGET_CERT_REVOCATION_MODE=offline` in the `dotnet10` stack image (0.1.2); signatures are still verified |
| Build still hung after restore was fixed | eShopOnWeb's Web project runs LibMan at build time, downloading jQuery/Bootstrap from cdnjs | `buildEnv: {LibraryRestore: "false"}` in the HelmRelease (0.1.2); tests do not need the assets |
| The agent's PR commit was authored `agent <agent@example.com>` | The model committed with its own identity | `verify` squashes each run into one commit by the role's bot with `Issue:`/`Run-Id:` trailers (0.1.3; not yet seen live) |
| Claude reported its Bash sandbox could not start and ran commands unsandboxed | bubblewrap needs to create a user namespace, which the pods' `RuntimeDefault` seccomp profile forbids (the nodes allow it) ([gotchas-cluster](gotchas-cluster.md#runtimedefault-seccomp-blocks-user-namespaces-in-pods)) | `sandbox: false` by default (0.1.3); the pod boundary is the control. The 0.1.3 notes blame Talos; that was wrong |

With these, one issue went end to end: plan (6 turns, about $0.08 estimated), implementation (10 turns, about $0.15, gate about
2 minutes), independent review (5 turns, about $0.07) to `ai-awaiting-merge` (JasonKoopmans/eShopOnWeb PR #2). The fork's own CI
`build` check needed its end-to-end tests filtered out first (fork PR #3): they need a configured running Web app, not just a browser.

## Open items

Placeholder resources, the token expiry, the sandbox decision and the fork's excluded end-to-end tests are tracked in
[revisit-register](revisit-register.md) (#21 to #24).
