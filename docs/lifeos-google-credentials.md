# Google credentials for LifeOS

How the LifeOS Grafana authenticates to Google Sheets, and why it gets its own
identity rather than borrowing n8n's.

**Short version:** one GCP project for the homelab, one service account per
consumer, and access granted by *sharing a Drive folder* with each service
account — not by GCP IAM roles.

---

## Why not reuse the n8n credential

Two reasons, and the first one settles it on its own.

**The auth models don't match.** n8n's Google nodes default to OAuth2: you click
through a consent screen and n8n stores a refresh token that lets it act *as
you*. Grafana's Sheets plugin cannot do OAuth2 at all — it supports a service
account (JWT), a plain API key (public sheets only), or GCE metadata (not
available on Talos). So Grafana needs a service account whether or not n8n has
one. There is nothing to reuse.

Worth confirming what n8n is actually using — **Credentials** in the n8n UI. It
isn't in this repo either way: n8n keeps credentials in its own encrypted store
on its PVC, so unlike Grafana's, that credential is invisible to Git and to
this documentation.

**And even if the models matched, you'd still want them split:**

- *Different verbs.* n8n writes to sheets; Grafana only ever reads. A read-only
  identity means a compromised Grafana cannot mutate your data — a property you
  lose the moment the two share a credential.
- *Independent rotation.* Rotating a key because one system leaked it shouldn't
  take the other one down with it.
- *Legible audit and sharing.* Drive's "shared with" list and Google's audit
  logs name the identity. `grafana-lifeos@…` and `n8n@…` tell you who read what;
  one shared `homelab@…` tells you nothing.
- *Quota isolation.* The Sheets API allows ~300 read requests/min per project
  but only ~60 per minute **per identity**. A Grafana dashboard with a dozen
  panels on a 1-minute refresh can eat a 60/min bucket by itself. Separate
  service accounts mean a busy dashboard cannot starve an n8n workflow.

---

## The layout

```
GCP project  hiro-homelab                     ← one project: billing + API enablement
├── SA  grafana-lifeos@…                      ← read-only reporting
└── SA  n8n@…              (only if n8n ever moves off OAuth2)

Google Drive
└── 📁 LifeOS                                 ← shared once, with grafana-lifeos as Viewer
    ├── 📄 spend-2026
    ├── 📄 habits
    └── …                                     ← new sheets inherit access
```

One project, because a project is a billing and API-enablement boundary, not a
security boundary — two projects would double the maintenance for no isolation.
The service account is the identity boundary, and that's where the split goes.

The **shared folder** is the part worth getting right. Service accounts have no
Drive of their own to browse; they see exactly the files shared with them. Share
one folder as Viewer and every sheet you drop in it becomes visible
automatically — otherwise you're back to per-sheet sharing every time you start
a new report, and eventually you forget and debug an empty panel instead.

---

## Setup

### 1. Project and APIs

```sh
PROJECT_ID=hiro-homelab          # or an existing project
gcloud config set project "$PROJECT_ID"

# Sheets API reads cell values. Drive API backs the spreadsheet picker in the
# panel editor — skip it only if you intend to paste spreadsheet IDs by hand.
gcloud services enable sheets.googleapis.com drive.googleapis.com
```

### 2. Service account and key

```sh
gcloud iam service-accounts create grafana-lifeos \
  --display-name="Grafana LifeOS" \
  --description="Read-only Google Sheets access for the LifeOS Grafana"

SA_EMAIL="grafana-lifeos@${PROJECT_ID}.iam.gserviceaccount.com"

umask 077
gcloud iam service-accounts keys create ~/grafana-lifeos.json \
  --iam-account="$SA_EMAIL"
```

**Do not grant the service account any project IAM role.** This trips people up:
Sheets and Drive access comes from *file sharing*, not from `roles/viewer` or
anything else in the IAM tab. A project role adds reach without adding access to
a single spreadsheet.

### 3. Share the data

Create a **LifeOS** folder in Drive, move the sheets you want to report on into
it, then share the folder with `$SA_EMAIL` as **Viewer** — the same dialog you'd
use for a person. Uncheck "Notify people"; nobody's reading that mailbox.

If your Drive is on a Google Workspace domain with external sharing restricted,
a service account from a project outside the org counts as external. Either put
the project in the same org, or share individual files, or ask the Workspace
admin to allow it.

### 4. Fill in the SOPS secret

From the repo root, with the key file still on disk:

```sh
KEY=~/grafana-lifeos.json

cat > kubernetes/apps/lifeos/grafana/app/secret.sops.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
type: Opaque
stringData:
  admin-user: admin
  admin-password: "$(openssl rand -base64 24)"
  secret-key: "$(openssl rand -base64 32)"
  googlesheets-client-email: "$(jq -r .client_email "$KEY")"
  googlesheets-project-id: "$(jq -r .project_id "$KEY")"
  googlesheets-private-key: |
$(jq -r .private_key "$KEY" | sed 's/^/    /')
EOF

sops --encrypt --in-place kubernetes/apps/lifeos/grafana/app/secret.sops.yaml
shred -u "$KEY"
```

`jq -r` is doing real work on the last field: the JSON key file stores the
private key with literal `\n` escapes, and `-r` expands them into the actual
newlines a PEM needs. Copy-pasting that field out of the JSON by hand is the
single most common way this integration fails.

`secret-key` is Grafana's own database encryption key, unrelated to Google. Set
it once and never rotate it — see `docs/lifeos-grafana.md`.

Check the round-trip before committing:

```sh
sops --decrypt kubernetes/apps/lifeos/grafana/app/secret.sops.yaml \
  | yq '.stringData.googlesheets-private-key' | head -2
# -----BEGIN PRIVATE KEY-----
# MIIEv…
```

Then commit and push; Flux reconciles and Reloader restarts the pod.

### 5. Verify

In Grafana: **Connections → Data sources → Google Sheets → Save & test**. The
data source is provisioned, so the form is read-only — the test button still
works.

- *"Invalid JWT" / "invalid_grant"* → the private key is mangled. Almost always
  the `\n` problem from step 4.
- *Test passes but a panel returns nothing* → the sheet isn't shared with
  `$SA_EMAIL`, or it's outside the shared folder.
- *"API has not been used in project…"* → step 1 didn't run, or ran against a
  different project than the key belongs to.

Pod-side: `kubectl -n lifeos logs deploy/grafana -c grafana | grep -i sheets`.

---

## Rotation

Service account keys don't expire on their own, so this is on you. Rotating is
additive — create the new key first, so there's no window without a valid one:

```sh
gcloud iam service-accounts keys create ~/grafana-lifeos-new.json \
  --iam-account="$SA_EMAIL"
# redo step 4 with the new file, commit, push
# once the pod is up and the data source tests green:
gcloud iam service-accounts keys list --iam-account="$SA_EMAIL"
gcloud iam service-accounts keys delete <OLD_KEY_ID> --iam-account="$SA_EMAIL"
```

Reloader restarts the pod on the secret change, so no manual rollout.

**Revoking entirely** — deleting the service account, or un-sharing the folder —
takes effect immediately and touches nothing else. That independence is the
whole point of not sharing an identity with n8n.

---

## Don't

- **Domain-wide delegation.** It lets the service account impersonate every user
  in a Workspace domain. It is occasionally the right tool and never the right
  tool here; folder sharing does the job with none of the blast radius.
- **API key auth.** The plugin supports it, but it only reads spreadsheets
  published to "anyone with the link" — which is the opposite of what personal
  data wants.
- **Sharing your whole Drive** with the service account. Share the LifeOS folder;
  a compromised key then reads your reports, not your tax returns.
- **Committing the JSON key file.** Only the three extracted fields go into the
  SOPS secret. `shred -u` the original, and mind your shell history — a leading
  space keeps a command out of it in most shells.
