#!/usr/bin/env bash
# provision-postgres-backup-iam.sh
#
# One-time bootstrap of the AWS side of the CloudNativePG backup target:
# an S3 bucket, a least-privilege IAM user scoped to *only* that bucket, and
# the SOPS-encrypted Secret the Barman Cloud plugin reads its credentials from.
#
# Why a dedicated IAM user (not the Longhorn backup identity):
#   The Longhorn credential can read and delete the cluster's volume backups.
#   Sharing it would mean a compromise of the Postgres backup sidecar also
#   reaches the volume backups — the two recovery paths would fail together,
#   which defeats the point of having both.
#
# Why the bucket hygiene below is not optional:
#   * Versioning + a noncurrent-version lifecycle rule. Barman prunes by issuing
#     DELETEs. On a versioned bucket a DELETE only writes a delete marker, so
#     without an expiry rule the "pruned" data is still billed forever.
#   * Aborting incomplete multipart uploads. Base backups upload in parts. A
#     sidecar killed mid-upload (OOM, node loss, failover) orphans those parts.
#     They are invisible in the console and billed indefinitely.
#
# Object Lock: this script enables the *capability* at bucket creation but sets
#   no retention rule, because retention interacts with Barman's own pruning and
#   is a deliberate decision deferred to the observability phase (see
#   docs/plan-cloudnative-pg.md §5). Enabling the capability later is awkward,
#   so it is turned on now while it is free to do so. No object is locked until
#   a retention rule is configured.
#
# Safe to re-run: every step checks for existing state first. The only step that
# refuses rather than adapts is access-key creation, since IAM caps a user at
# two keys and silently creating a second is how you end up not knowing which
# one is live.
#
# Usage:
#   bash scripts/provision-postgres-backup-iam.sh [--region REGION] [--user NAME]
#                                                 [--dry-run] [--yes]
#
# There is deliberately no --bucket flag. The bucket is read from
# destinationPath in the ObjectStore manifest, which is what Barman actually
# reads at runtime, so the two cannot drift. To target a different bucket, edit
# the manifest first.
#
#   --dry-run   Make no changes. Read-only discovery still runs (caller identity,
#               head-bucket, get-policy, get-user) because the point of a dry run
#               is to report what *would* happen given real state — so it does
#               need working AWS credentials. Every mutating call is printed
#               rather than executed. Start here.
#   --yes       Skip the confirmation prompt.
#
# Note the `bash scripts/...` invocation: in the devcontainer the repo is a
# fakeowner mount and the executable bit does not survive, so `./scripts/...`
# fails. Run it from the repo root.
#
# Requires: awscli v2, sops, jq, python3 (used to decode IAM policy documents
# for the reuse check), and an age key at ./age.key for the final encrypt step.
# AWS credentials must already be configured with rights to create S3 buckets
# and IAM users — this script does not manage that identity.

set -euo pipefail

# awscli pipes through a pager that does not exist in the devcontainer.
export AWS_PAGER=""

REGION="us-east-1"
IAM_USER="hiro-postgres-backup"
DRY_RUN=false
ASSUME_YES=false

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${REPO_ROOT}/kubernetes/apps/database/postgres/app"
SECRET_FILE="${APP_DIR}/s3-credentials.sops.yaml"
OBJECTSTORE_FILE="${APP_DIR}/objectstore.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --user)   IAM_USER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    # `\?` is a GNU-sed extension; use two portable expressions instead so this
    # also works under BSD sed on macOS.
    -h|--help) sed -n '2,52p' "${BASH_SOURCE[0]}" | sed -e 's/^# //' -e 's/^#$//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# The bucket is NOT a parameter of this script. It is read out of the
# ObjectStore manifest, which is the thing Barman actually reads at runtime.
# An earlier version took --bucket, which meant `--bucket other` would create
# and authorize `other` while Barman kept writing to whatever the manifest said
# — provisioning "succeeds" and every backup then fails with AccessDenied.
# To target a different bucket, edit destinationPath first; the manifest leads.
[[ -f "$OBJECTSTORE_FILE" ]] || die "ObjectStore manifest not found: $OBJECTSTORE_FILE"

DEST_PATH="$(grep -E '^[[:space:]]*destinationPath:' "$OBJECTSTORE_FILE" \
  | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//; s#^s3://##; s#/$##')"
[[ -n "$DEST_PATH" ]] || die "could not parse destinationPath from $OBJECTSTORE_FILE"

BUCKET="${DEST_PATH%%/*}"
PREFIX="${DEST_PATH#*/}"
[[ "$PREFIX" == "$BUCKET" ]] && PREFIX=""   # destinationPath had no key prefix
[[ -n "$BUCKET" ]] || die "parsed an empty bucket from destinationPath '$DEST_PATH'"

# Fixed name, not bucket-suffixed. The risk of a fixed name — silently reusing a
# policy created for a different bucket — is handled by validating the existing
# policy's Resource ARNs before attaching it (see below), which fails loudly
# instead. Encoding the bucket in the name would additionally leave the previous
# policy created-and-attached, so the user ends up with two, one of which grants
# the wrong bucket. Validation is the better half of that pair.
POLICY_NAME="hiro-postgres-backup-s3"

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '\033[0;90m  [dry-run] %s\033[0m\n' "$*"
    return 0
  fi
  "$@"
}

# Every S3 call goes through this so --region is never accidentally omitted.
# Without it the CLI falls back to its *configured* region while the Secret
# still tells Barman $REGION — the bucket gets created correctly and then
# configuration calls fail or hit the wrong endpoint.
s3api() { aws s3api --region "$REGION" "$@"; }

# ---------------------------------------------------------------- preflight --

for bin in aws jq sops python3; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required binary: $bin"
done

[[ -f "$SECRET_FILE" ]] || die "secret file not found: $SECRET_FILE"

# Prove SOPS can actually encrypt BEFORE anything irreversible happens.
#
# This ordering is the whole point: minting the access key first means a missing
# or invalid age key leaves you holding a live AWS credential *and* a plaintext
# secret on disk — and the two-key guard further down then refuses to mint a
# replacement, so the next run cannot recover either. Fail here instead, where
# nothing has been created yet and there is nothing to clean up.
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${REPO_ROOT}/age.key}"
[[ -f "$AGE_KEY_FILE" ]] || die "age key not found: ${AGE_KEY_FILE} (set SOPS_AGE_KEY_FILE)"

# The probe MUST live inside the repo under a *.sops.yaml name. SOPS resolves
# its recipient from the `creation_rules` path_regex in .sops.yaml, which only
# matches `(bootstrap|kubernetes)/.*\.sops\.ya?ml`. A probe under /tmp matches
# nothing and dies with "no matching creation rules found" — which would abort
# this preflight on *every* invocation, before any provisioning happens.
CLEANUP_FILES=()
cleanup() {
  local f
  for f in ${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}; do
    [[ -n "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT INT TERM

SOPS_PROBE="${APP_DIR}/.sops-preflight-probe.sops.yaml"
CLEANUP_FILES+=("$SOPS_PROBE")
(
  umask 077
  cat >"$SOPS_PROBE" <<'PROBE'
apiVersion: v1
kind: Secret
stringData:
  probe: canary
PROBE
)
if ! SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
     sops --encrypt --in-place "$SOPS_PROBE" >/dev/null 2>&1; then
  die "sops cannot encrypt ${SOPS_PROBE#"$REPO_ROOT"/} using ${AGE_KEY_FILE##*/} — fix this before provisioning anything"
fi
rm -f "$SOPS_PROBE"
log "sops encryption verified against ${AGE_KEY_FILE#"$REPO_ROOT"/}"

CALLER="$(aws sts get-caller-identity --output json 2>/dev/null)" \
  || die "aws sts get-caller-identity failed — configure AWS credentials first"
ACCOUNT_ID="$(jq -r .Account <<<"$CALLER")"

log "AWS account : $ACCOUNT_ID"
log "Identity    : $(jq -r .Arn <<<"$CALLER")"
log "Bucket      : s3://${BUCKET}/${PREFIX}  (region ${REGION})"
log "IAM user    : ${IAM_USER}"
log "Secret file : ${SECRET_FILE#"$REPO_ROOT"/}"

if [[ "$DRY_RUN" == false && "$ASSUME_YES" == false ]]; then
  read -r -p "Create these resources in account ${ACCOUNT_ID}? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted"
fi

# ------------------------------------------------------------------- bucket --

if s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "bucket ${BUCKET} already exists — skipping creation"

  # Object Lock can only be turned on at creation time. Skipping the creation
  # branch would otherwise mean this script reports the capability as enabled
  # while silently accepting a bucket that can never have it.
  if s3api get-object-lock-configuration --bucket "$BUCKET" >/dev/null 2>&1; then
    log "existing bucket has Object Lock enabled"
  else
    warn "bucket ${BUCKET} exists WITHOUT Object Lock enabled."
    warn "It cannot be added to an existing bucket. Everything else here still"
    warn "applies, but the deferred Object Lock option (see"
    warn "docs/plan-cloudnative-pg.md) is unavailable unless the bucket is"
    warn "recreated. Continuing."
  fi

  ACTUAL_REGION="$(s3api get-bucket-location --bucket "$BUCKET" \
    --query 'LocationConstraint' --output text 2>/dev/null || echo "")"
  # us-east-1 is reported as the literal string "None".
  [[ "$ACTUAL_REGION" == "None" || -z "$ACTUAL_REGION" ]] && ACTUAL_REGION="us-east-1"
  if [[ "$ACTUAL_REGION" != "$REGION" ]]; then
    die "bucket ${BUCKET} is in ${ACTUAL_REGION} but --region says ${REGION}. The Secret would tell Barman the wrong region — re-run with --region ${ACTUAL_REGION}"
  fi
else
  log "creating bucket ${BUCKET}"
  # us-east-1 is the one region that rejects an explicit LocationConstraint.
  if [[ "$REGION" == "us-east-1" ]]; then
    run s3api create-bucket \
      --bucket "$BUCKET" \
      --object-lock-enabled-for-bucket
  else
    run s3api create-bucket \
      --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=${REGION}" \
      --object-lock-enabled-for-bucket
  fi
fi

log "blocking all public access"
run s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

log "enforcing bucket-owner ownership (disables ACLs)"
run s3api put-bucket-ownership-controls \
  --bucket "$BUCKET" \
  --ownership-controls "Rules=[{ObjectOwnership=BucketOwnerEnforced}]"

# Object Lock forces versioning on, but set it explicitly so this stays correct
# if --object-lock-enabled-for-bucket is ever dropped.
log "enabling versioning"
run s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration "Status=Enabled"

# BucketKeyEnabled is deliberately absent: S3 Bucket Keys are an SSE-KMS
# request-cost optimization and carry no meaning under SSE-S3 (AES256).
log "enabling default server-side encryption (SSE-S3)"
run s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

log "applying lifecycle rules (orphaned multipart parts, noncurrent versions)"
run s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "abort-incomplete-multipart-uploads",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
      },
      {
        "ID": "expire-noncurrent-versions",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "NoncurrentVersionExpiration": {"NoncurrentDays": 30}
      }
    ]
  }'

# ---------------------------------------------------------------------- IAM --

# Scoped to this bucket only. Deliberately NOT scoped further to the
# "${PREFIX}/" key prefix: the bucket is dedicated to these backups, so prefix
# conditions buy no isolation while adding a way for a destinationPath change to
# silently break archiving.
POLICY_DOC="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BucketLevel",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::${BUCKET}"
    },
    {
      "Sid": "ObjectLevel",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    }
  ]
}
EOF
)"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "policy ${POLICY_NAME} already exists — verifying it actually grants ${BUCKET}"

  # Never attach a pre-existing policy without checking what it authorizes.
  # Attaching one scoped to a different bucket leaves the workload with
  # credentials that authenticate fine and are denied on every operation.
  DEFAULT_VER="$(aws iam get-policy --policy-arn "$POLICY_ARN" \
    --query 'Policy.DefaultVersionId' --output text 2>/dev/null)"

  # `PolicyVersion.Document` comes back as a URL-encoded JSON *string*, not an
  # object, so a `--query 'Document.Statement[].Resource'` yields nothing and
  # every rerun would fall into the refusal branch below. Decode explicitly, and
  # tolerate an already-decoded object in case the CLI ever changes.
  #
  # Compare against the exact expected ARN set rather than merely checking that
  # the bucket is mentioned: a policy granting "*" or extra buckets also
  # "mentions" this one, and attaching it would quietly hand the backup user far
  # more than it needs.
  POLICY_RESOURCES="$(aws iam get-policy-version \
    --policy-arn "$POLICY_ARN" --version-id "$DEFAULT_VER" --output json 2>/dev/null \
    | python3 -c '
import json, sys, urllib.parse
try:
    doc = json.load(sys.stdin)["PolicyVersion"]["Document"]
except Exception:
    print("[]"); raise SystemExit(0)
if isinstance(doc, str):
    doc = json.loads(urllib.parse.unquote(doc))
out = []
for st in doc.get("Statement", []):
    r = st.get("Resource", [])
    out.extend(r if isinstance(r, list) else [r])
print(json.dumps(sorted(set(out))))
' 2>/dev/null || echo '[]')"

  EXPECTED_RESOURCES="$(python3 -c '
import json, sys
b = sys.argv[1]
print(json.dumps(sorted({f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"})))
' "$BUCKET")"

  if [[ "$POLICY_RESOURCES" == "$EXPECTED_RESOURCES" ]]; then
    log "existing policy grants exactly ${BUCKET} — leaving as-is"
  else
    warn "policy ${POLICY_NAME} does not grant exactly the expected resources."
    warn "  expected: ${EXPECTED_RESOURCES}"
    warn "  actual:   ${POLICY_RESOURCES}"
    die "refusing to attach it — it may authorize the wrong bucket, or more than this user needs. Publish a corrected version, then re-run:
  aws iam create-policy-version --policy-arn ${POLICY_ARN} --set-as-default --policy-document '<json>'"
  fi
else
  log "creating policy ${POLICY_NAME}"
  run aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --description "Least-privilege access to s3://${BUCKET} for CloudNativePG Barman Cloud backups" \
    --policy-document "$POLICY_DOC"
fi

if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
  log "IAM user ${IAM_USER} already exists — skipping creation"
else
  log "creating IAM user ${IAM_USER}"
  run aws iam create-user \
    --user-name "$IAM_USER" \
    --tags "Key=purpose,Value=cloudnative-pg-backups" "Key=managed-by,Value=home-ops-hiro"
fi

log "attaching policy to user"
run aws iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$POLICY_ARN"

# ------------------------------------------------------------- access key ----

if [[ "$DRY_RUN" == true ]]; then
  printf '\033[0;90m  [dry-run] aws iam create-access-key --user-name %s\033[0m\n' "$IAM_USER"
  printf '\033[0;90m  [dry-run] write + sops --encrypt --in-place %s\033[0m\n' "${SECRET_FILE#"$REPO_ROOT"/}"
  log "dry run complete — no resources created"
  exit 0
fi

# `--output text` renders an empty JMESPath result as the literal "None" rather
# than an empty string, which would make the very first run — the one that has
# no keys yet — report a key called "None" and exit without creating one. Parse
# JSON and test the array instead.
EXISTING_KEYS="$(aws iam list-access-keys --user-name "$IAM_USER" --output json 2>/dev/null \
  | jq -r '[.AccessKeyMetadata[]?.AccessKeyId] | join(" ")' 2>/dev/null || true)"

if [[ -n "${EXISTING_KEYS// /}" ]]; then
  warn "user ${IAM_USER} already has access key(s): ${EXISTING_KEYS}"
  warn "Refusing to mint another — IAM allows only two, and a spare you cannot"
  warn "identify is worse than none. To rotate deliberately:"
  warn "  aws iam delete-access-key --user-name ${IAM_USER} --access-key-id <OLD_ID>"
  warn "  then re-run this script."
  die "no access key created; bucket and IAM state above are correct and re-runnable"
fi

log "creating access key"
KEY_JSON="$(aws iam create-access-key --user-name "$IAM_USER" --output json)"
ACCESS_KEY_ID="$(jq -r .AccessKey.AccessKeyId <<<"$KEY_JSON")"
SECRET_ACCESS_KEY="$(jq -r .AccessKey.SecretAccessKey <<<"$KEY_JSON")"
unset KEY_JSON

# ------------------------------------------------------- write + encrypt -----

# Write plaintext to a 0600 scratch file, encrypt it *there*, and only then move
# the already-encrypted result over the tracked path. Writing plaintext directly
# to the tracked file meant an interrupted run — killed sops, Ctrl-C, power loss
# — could leave a live AWS secret sitting at a git-tracked path, staged by the
# next `git add`. With this ordering the tracked file is either untouched or
# encrypted, never plaintext, and the trap removes the scratch file on any exit.
#
# The scratch file has to live beside the real one and keep a *.sops.yaml name,
# for the same creation_rules reason as the preflight probe above.
SECRET_TMP="${APP_DIR}/.s3-credentials.provisioning.sops.yaml"
CLEANUP_FILES+=("$SECRET_TMP")

log "writing and encrypting ${SECRET_FILE#"$REPO_ROOT"/}"
(
  umask 077
  cat >"$SECRET_TMP" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-s3-backup-secret
stringData:
  AWS_ACCESS_KEY_ID: ${ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${SECRET_ACCESS_KEY}
  AWS_REGION: ${REGION}
EOF
)
unset SECRET_ACCESS_KEY

SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
  sops --encrypt --in-place "$SECRET_TMP" \
  || die "sops encryption FAILED. The tracked secret was left untouched; the plaintext scratch file is being removed. Access key ${ACCESS_KEY_ID} is live — delete it with: aws iam delete-access-key --user-name ${IAM_USER} --access-key-id ${ACCESS_KEY_ID}"

# Verify the scratch file before it is allowed anywhere near the tracked path.
if ! grep -q "^sops:" "$SECRET_TMP" || grep -q "${ACCESS_KEY_ID}" "$SECRET_TMP"; then
  die "post-encryption check FAILED — scratch file is not properly encrypted and will be removed. Access key ${ACCESS_KEY_ID} is live; delete it with: aws iam delete-access-key --user-name ${IAM_USER} --access-key-id ${ACCESS_KEY_ID}"
fi

# Atomic: the tracked path goes straight from old content to fully-encrypted.
mv -f "$SECRET_TMP" "$SECRET_FILE"
chmod 0600 "$SECRET_FILE"
log "verified: ${SECRET_FILE#"$REPO_ROOT"/} is encrypted and contains no plaintext key id"

# ------------------------------------------------------------------- next ----

cat <<EOF

$(log "done")

  Bucket        s3://${BUCKET}/${PREFIX}
  IAM user      ${IAM_USER}  (access key ${ACCESS_KEY_ID})
  Secret        ${SECRET_FILE#"$REPO_ROOT"/}  [encrypted]

Next, to bring up the cluster:

  1. Register the app — add this line to
     kubernetes/apps/database/kustomization.yaml under resources:

       - ./postgres/ks.yaml

  2. Verify it renders:

       kubectl kustomize kubernetes/apps/database >/dev/null && echo OK

  3. Commit the postgres app together with that registration line. Committing
     one without the other breaks the whole database group build, mariadb
     included.

  4. After Flux reconciles, confirm archiving actually works — a green
     Kustomization does not mean backups run:

       kubectl -n database get cluster postgres
       kubectl -n database get objectstore postgres-backup
       kubectl -n database logs -l cnpg.io/cluster=postgres -c plugin-barman-cloud --tail=50
       aws s3 ls s3://${BUCKET}/${PREFIX}/ --recursive | head

EOF
