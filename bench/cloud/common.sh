#!/usr/bin/env bash
# Shared helpers for bench/cloud scripts. Source this file; do not run it.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

BENCH_PREFIX="hayaoki-bench"
AWS_REGION_FIXED="ap-northeast-1"
GCP_REGION_FIXED="asia-northeast1"

CLOUD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CLOUD_DIR/../.." && pwd)"
TARGET_FILE="$CLOUD_DIR/results/.target"   # optional, gitignored: lines "aws_account=<12 digits>" / "gcp_project=<id>"

ASSUME_YES=0
BACKGROUND=0

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

# confirm "message": y/N on the terminal; --yes skips it (used by the --background child).
confirm() {
  local ans
  [[ "$ASSUME_YES" == 1 ]] && return 0
  printf '%s [y/N] ' "$1" >&2
  read -r ans </dev/tty || die "no terminal for confirmation"
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted"
}

# maybe_background LOGFILE ARGS...: with --background, re-run this script (same args plus --yes, without
# --background) under nohup, logging to LOGFILE, and exit. Call it right after the foreground confirmations.
maybe_background() {
  local logfile="$1"; shift
  [[ "$BACKGROUND" == 1 ]] || return 0
  local args=() a
  for a in "$@"; do [[ "$a" == --background ]] || args+=("$a"); done
  mkdir -p "$(dirname "$logfile")"
  BACKGROUND=0 nohup "$0" "${args[@]}" --yes </dev/null >> "$logfile" 2>&1 &
  echo "running in background (pid $!), log: $logfile" >&2
  exit 0
}

# Run the gem's own CLI from this checkout (no install needed).
hayaoki_cli() { ruby -I"$REPO_ROOT/lib" "$REPO_ROOT/exe/hayaoki" "$@"; }

# Seconds since the epoch with milliseconds (macOS date has no %N).
now_s() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
diff_s() { perl -e 'printf "%.3f", $ARGV[1] - $ARGV[0]' "$1" "$2"; }

# Number of non-blank lines in a file (0 if missing).
count_lines() { [[ -f "$1" ]] && awk 'NF { c++ } END { print c + 0 }' "$1" || echo 0; }

# expected_value KEY GIVEN: GIVEN (from a flag) or the value in results/.target.
expected_value() {
  local key="$1" given="${2:-}"
  if [[ -n "$given" ]]; then echo "$given"; return; fi
  [[ -f "$TARGET_FILE" ]] && sed -n "s/^$key=//p" "$TARGET_FILE" | head -n1 || true
}

# --- AWS ---------------------------------------------------------------
# aws_setup PROFILE EXPECT_ACCOUNT: validates and prints the target account. Use "${AWS[@]}" for every aws call.
aws_setup() {
  local profile="${1:-}" expect
  expect="$(expected_value aws_account "${2:-}")"
  [[ -n "$profile" ]] || die "--profile is required (no default)"
  [[ "$expect" =~ ^[0-9]{12}$ ]] || die "--expect-account <12 digits> is required (or aws_account= in results/.target)"
  command -v aws >/dev/null || die "aws CLI not found"
  AWS=(aws --profile "$profile" --region "$AWS_REGION_FIXED")
  AWS_PROFILE_NAME="$profile"
  local ident
  ident="$("${AWS[@]}" sts get-caller-identity --output text --query '[Account,Arn]')" \
    || die "aws sts get-caller-identity failed for profile '$profile'"
  AWS_ACCOUNT_ID="${ident%%$'\t'*}"
  echo "AWS target: profile=$profile region=$AWS_REGION_FIXED account/arn: $ident" >&2
  [[ "$AWS_ACCOUNT_ID" == "$expect" ]] || die "account of profile '$profile' does not match the expected account"
}

# --- GCP ---------------------------------------------------------------
# gcp_setup CONFIG PROJECT EXPECT_PROJECT: pins the gcloud configuration and project. Use "${GC[@]}" for every gcloud call.
gcp_setup() {
  local config="${1:-}" project="${2:-}" expect
  expect="$(expected_value gcp_project "${3:-}")"
  [[ -n "$config" ]]  || die "--gcloud-config is required (no default)"
  [[ -n "$project" ]] || die "--project is required (no default)"
  [[ -n "$expect" ]]  || die "--expect-project is required (or gcp_project= in results/.target)"
  [[ "$project" == "$expect" ]] || die "--project does not match the expected project"
  command -v gcloud >/dev/null || die "gcloud not found"
  export CLOUDSDK_ACTIVE_CONFIG_NAME="$config"
  [[ "$(gcloud config get project 2>/dev/null)" == "$project" ]] \
    || die "gcloud configuration '$config' has a different core/project than --project"
  GC=(gcloud --project "$project")
  GCP_PROJECT="$project"
  GCP_PROJECT_NUMBER="$(gcloud projects describe "$project" --format='value(projectNumber)' 2>/dev/null || true)"
  [[ "$GCP_PROJECT_NUMBER" =~ ^[0-9]+$ ]] || die "cannot read the project number (needed for masking)"
  GCP_ACCOUNT="$(gcloud config get account 2>/dev/null)"
  [[ -n "$GCP_ACCOUNT" ]] || die "no active account in gcloud configuration '$config'"
  echo "GCP target: configuration=$config project=$project region=$GCP_REGION_FIXED account=$GCP_ACCOUNT" >&2
}

# --- app build contexts --------------------------------------------------
# prepare_context APP TARGET OUTDIR   APP: minimal|redmine   TARGET: cloud_run|lambda
prepare_context() {
  local app="$1" target="$2" dir="$3" exdir
  case "$target" in cloud_run) exdir=cloud_run ;; lambda) exdir=lambda_lwa ;; *) die "bad target $target" ;; esac
  rm -rf "$dir"; mkdir -p "$dir"
  case "$app" in
    minimal)
      "$CLOUD_DIR/apps/gen_minimal.sh" "$dir"
      cp "$REPO_ROOT/examples/$exdir/Dockerfile" "$dir/Dockerfile"
      ;;
    redmine)
      cp "$CLOUD_DIR/apps/redmine/Dockerfile" "$dir/Dockerfile"
      cp "$REPO_ROOT/examples/puma.rb" "$dir/puma.rb"
      ;;
    *) die "unknown app '$app' (minimal|redmine)" ;;
  esac
}

# Wait N minutes, logging every 5 minutes.
wait_minutes() {
  local m="$1" i
  for ((i = 0; i < m; i++)); do
    sleep 60
    if (( (i + 1) % 5 == 0 )); then log "waiting: $((i + 1))/$m min"; fi
  done
}

# build_with_cloud_build IMAGE CONTEXT TARGET: linux/amd64 build in Cloud Build, pushed to Artifact Registry
# only. No credentials of another cloud are ever given to Cloud Build. TARGET may be empty (no --target).
build_with_cloud_build() {
  local image="$1" ctx="$2" target="$3" cfg="$2/.cloudbuild.yaml" targetargs=""
  [[ -n "$target" ]] && targetargs="\"--target\", \"$target\", "
  cat > "$cfg" <<YAML
steps:
  - name: gcr.io/cloud-builders/docker
    args: ["build", ${targetargs}"-t", "$image", "."]
images: ["$image"]
YAML
  "${GC[@]}" builds submit "$ctx" --config "$cfg" --region "$GCP_REGION_FIXED"
  rm -f "$cfg"
}

# copy_ar_to_ecr AR_IMAGE ECR_IMAGE: copies locally with crane. Passwords go through stdin only.
copy_ar_to_ecr() {
  local src="$1" dst="$2"
  command -v crane >/dev/null || die "crane not found (brew install crane)"
  gcloud auth print-access-token | crane auth login "${src%%/*}" -u oauth2accesstoken --password-stdin
  "${AWS[@]}" ecr get-login-password | crane auth login "${dst%%/*}" -u AWS --password-stdin
  local rc=0
  crane copy "$src" "$dst" || rc=$?
  # crane stores the logins in ~/.docker/config.json; do not leave them there
  crane auth logout "${src%%/*}" >/dev/null 2>&1 || true
  crane auth logout "${dst%%/*}" >/dev/null 2>&1 || true
  return "$rc"
}

# --- masking ---------------------------------------------------------------
# mask_stream: stdin -> stdout. Replaces the real identifiers (known at runtime) and IDs by placeholders.
mask_stream() {
  M_GCP_PROJECT="${GCP_PROJECT:-}" M_GCP_NUMBER="${GCP_PROJECT_NUMBER:-}" M_GCP_ACCOUNT="${GCP_ACCOUNT:-}" \
  M_AWS_ACCOUNT="${AWS_ACCOUNT_ID:-}" M_AWS_PROFILE="${AWS_PROFILE_NAME:-}" \
  perl -pe '
    for my $p (["M_GCP_PROJECT","example-project"],["M_GCP_NUMBER","000000000000"],
               ["M_GCP_ACCOUNT","user\@example.com"],["M_AWS_ACCOUNT","123456789012"],
               ["M_AWS_PROFILE","example-profile"]) {
      my $v = $ENV{$p->[0]}; next unless length $v; s/\Q$v\E/$p->[1]/g;
    }
    s{[a-z0-9-]+\.[a-z0-9-]+\.run\.app}{service.example.com}g;
    s{[a-z0-9-]+-docker\.pkg\.dev}{registry.example.com}g;
    s{dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com}{ecr.example.com}g;
    s{arn:aws:}{arn:example:}g;
    s{AWSReservedSSO_[A-Za-z0-9_-]+}{ExampleRole}g;
    s{[A-Za-z0-9._-]+\@[A-Za-z0-9-]+\.iam\.gserviceaccount\.com}{sa\@example.com}g;
    s{\[\$LATEST\][0-9a-f]+}{[\$LATEST]<hex>}g;
    s{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}}{00000000-0000-0000-0000-000000000000}g;
    s{[0-9a-f]{40,}}{<hex>}g;
  '
}

# make_shareable OUTDIR RAWFILE: OUTDIR/shareable/ gets masked copies and reports built from masked data.
make_shareable() {
  local out="$1" raw="$2" sh="$1/shareable"
  mkdir -p "$sh"; rm -f "$sh/.REVIEW_NEEDED"
  mask_stream < "$raw" > "$sh/cold_start.jsonl"
  mask_stream < "$out/config.txt" > "$sh/config.txt"
  hayaoki_cli cold-start-report "$sh/cold_start.jsonl" > "$sh/report.txt" || true
  hayaoki_cli cold-start-report --format json "$sh/cold_start.jsonl" > "$sh/report.json" || true
  hayaoki_cli cold-start-report --exclude-proactive "$sh/cold_start.jsonl" > "$sh/report_exclude_proactive.txt" || true
  [[ -f "$out/samples.csv" ]] && cp "$out/samples.csv" "$sh/samples.csv"
  local residue
  residue="$(cat "$sh"/* | sed -E 's/123456789012|000000000000//g' | grep -Eo \
    '(^|[^0-9])[0-9]{12}([^0-9]|$)|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+|\.run\.app|AWSReservedSSO|gserviceaccount|arn:aws|dkr\.ecr|docker\.pkg\.dev' \
    | grep -v '@example\.com' || true)"
  if [[ -n "$residue" ]]; then
    : > "$sh/.REVIEW_NEEDED"
    log "WARNING: $sh may still contain identifiers (see .REVIEW_NEEDED); do not share it before checking: $(head -n3 <<<"$residue" | tr '\n' ' ')"
  fi
}

# ar_keep_latest REPO LOCATION: at most one version (the newest) of each image in an Artifact Registry repo.
# Cleanup runs asynchronously on Google's side (about once a day); KEEP wins over DELETE.
ar_keep_latest() {
  local repo="$1" loc="$2" pol
  pol="$(mktemp)"
  cat > "$pol" <<'JSON'
[
  {"name": "delete-all", "action": {"type": "Delete"}, "condition": {"tagState": "any"}},
  {"name": "keep-newest", "action": {"type": "Keep"}, "mostRecentVersions": {"keepCount": 1}}
]
JSON
  "${GC[@]}" artifacts repositories set-cleanup-policies "$repo" --location "$loc" --policy "$pol" --no-dry-run >/dev/null
  rm -f "$pol"
}

# ecr_keep_latest REPO: tags are one per app, so a re-push leaves the old image untagged. The lifecycle
# rule is a backstop (it runs asynchronously, minimum count 1); ecr_prune_untagged deletes them right away.
ecr_keep_latest() {
  "${AWS[@]}" ecr put-lifecycle-policy --repository-name "$1" --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"keep only the newest untagged image","selection":{"tagStatus":"untagged","countType":"imageCountMoreThan","countNumber":1},"action":{"type":"expire"}}]}' >/dev/null
}

# ecr_prune_untagged REPO: delete untagged images now, so each app keeps at most one image.
ecr_prune_untagged() {
  local ids
  ids="$("${AWS[@]}" ecr list-images --repository-name "$1" --filter tagStatus=UNTAGGED --query 'imageIds[].imageDigest' --output text)"
  [[ -z "$ids" || "$ids" == None ]] && return 0
  local args=(); for d in $ids; do args+=("imageDigest=$d"); done
  "${AWS[@]}" ecr batch-delete-image --repository-name "$1" --image-ids "${args[@]}" >/dev/null
}

# ar_prune_untagged IMAGE_PATH (no tag): delete untagged versions of one AR image now.
ar_prune_untagged() {
  local d
  for d in $("${GC[@]}" artifacts docker images list "$1" --include-tags --filter='-tags:*' --format='value(version)' 2>/dev/null); do
    "${GC[@]}" artifacts docker images delete "$1@$d" --quiet >/dev/null
  done
}
