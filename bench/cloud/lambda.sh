#!/usr/bin/env bash
# Deploy an example image to PRIVATE Lambda functions (no Function URL, no API Gateway), sample cold
# starts by direct `aws lambda invoke`, collect hayaoki lines + REPORT lines from CloudWatch Logs,
# run `hayaoki cold-start-report`. One function per memory size (a "cell"). Teardown: teardown.sh.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
ORIG_ARGS=("$@")

usage() {
  cat >&2 <<USAGE
usage: lambda.sh --profile NAME --expect-account 12DIGITS --app minimal|redmine [options]
  (--expect-account may be replaced by aws_account= in results/.target)
  --samples N        cold starts to sample per cell (default 6)
  --interval-min M   idle minutes between rounds in natural mode (default 20)
  --memories "A B"   memory sizes in MB, one function each (default "1024 2048")
  --force-cold       smoke-test mode: bump an env var before each invoke (see README caveats)
  --builder B        local (docker) | cloudbuild (default local). cloudbuild builds into a private Artifact
                     Registry repo (needs --gcloud-config, --project, --expect-project; used only for the build)
                     and then copies the image to ECR locally with crane (brew install crane)
  --async-init       set AWS_LWA_ASYNC_INIT=true (for Init that may exceed 10 s; see README)
  --collect-only     skip deploy/sampling; just collect logs and report
  --skip-build       reuse the image already pushed (automatic when resuming)
  --background       confirm now, then continue under nohup (log: results/lambda-APP-FIRSTMEM/run.log)
  --yes              skip confirmations (the --background child uses it)
Resumable: re-running continues from results/lambda-APP-MEM/samples.csv.
USAGE
  exit 2
}

PROFILE="" APP="" N=6 INTERVAL=20 MEMS="1024 2048" FORCE=0 COLLECT_ONLY=0 SKIP_BUILD=0
BUILDER=local GCONF="" PROJECT="" EXPECT_PROJECT="" EXPECT_ACCOUNT="" ASYNC_INIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --expect-account) EXPECT_ACCOUNT="$2"; shift 2 ;;
    --expect-project) EXPECT_PROJECT="$2"; shift 2 ;;
    --async-init) ASYNC_INIT=1; shift ;;
    --background) BACKGROUND=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --app) APP="$2"; shift 2 ;;
    --samples) N="$2"; shift 2 ;;
    --interval-min) INTERVAL="$2"; shift 2 ;;
    --memories) MEMS="$2"; shift 2 ;;
    --force-cold) FORCE=1; shift ;;
    --builder) BUILDER="$2"; shift 2 ;;
    --gcloud-config) GCONF="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --collect-only) COLLECT_ONLY=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) usage ;;
  esac
done
[[ "$APP" == minimal || "$APP" == redmine ]] || usage
[[ "$BUILDER" == local || "$BUILDER" == cloudbuild ]] || die "--builder must be local or cloudbuild"
aws_setup "$PROFILE" "$EXPECT_ACCOUNT"
if [[ "$BUILDER" == cloudbuild ]]; then gcp_setup "$GCONF" "$PROJECT" "$EXPECT_PROJECT"; fi
FIRST_MEM="${MEMS%% *}"

REPO="$BENCH_PREFIX"
ROLE="$BENCH_PREFIX-lambda-role"
ECR_HOST="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION_FIXED.amazonaws.com"
IMAGE="$ECR_HOST/$REPO:$APP"
AR_IMAGE="$GCP_REGION_FIXED-docker.pkg.dev/${PROJECT:-none}/$REPO/lambda-$APP:v1"
fn_name() { echo "$BENCH_PREFIX-$APP-$1"; }
cell_dir() { echo "$CLOUD_DIR/results/lambda-$APP-$1"; }
SECRET_FILE="$CLOUD_DIR/results/.lambda-$APP-secret_key_base"
mkdir -p "$CLOUD_DIR/results"
[[ -f "$SECRET_FILE" ]] || openssl rand -hex 64 > "$SECRET_FILE"
SKB="$(cat "$SECRET_FILE")"

# Direct-invoke event: API Gateway HTTP API v2 / Function URL payload (payload format 2.0) for GET /.
# Lambda Web Adapter parses the invoke payload as an API Gateway / Function URL / ALB event and forwards
# it to the app as HTTP (README of aws/aws-lambda-web-adapter lists these event sources). UNVERIFIED for raw
# `aws lambda invoke`: the smoke run checks it (statusCode 200 in the response).
EVENT="$CLOUD_DIR/results/.lambda-event.json"
cat > "$EVENT" <<'JSON'
{"version":"2.0","routeKey":"$default","rawPath":"/","rawQueryString":"",
 "headers":{"host":"bench.example.com","x-forwarded-proto":"https","x-forwarded-port":"443","user-agent":"hayaoki-bench"},
 "requestContext":{"accountId":"anonymous","apiId":"bench","domainName":"bench.example.com","domainPrefix":"bench",
   "http":{"method":"GET","path":"/","protocol":"HTTP/1.1","sourceIp":"127.0.0.1","userAgent":"hayaoki-bench"},
   "requestId":"bench","routeKey":"$default","stage":"$default","time":"01/Jan/2026:00:00:00 +0000","timeEpoch":0},
 "isBase64Encoded":false}
JSON

write_config() {
  local mem="$1" d; d="$(cell_dir "$mem")"; mkdir -p "$d"
  {
    echo "platform=lambda function=$(fn_name "$mem") region=$AWS_REGION_FIXED app=$APP memory_mb=$mem arch=x86_64 timeout_s=60"
    echo "access=direct-invoke only (no Function URL, no API Gateway) role_policy=AWSLambdaBasicExecutionRole ecr=private"
    echo "mode=$([[ $FORCE == 1 ]] && echo force-cold || echo "natural interval_min=$INTERVAL") samples=$N"
  } > "$d/config.txt"
}

collect() {
  local mem d fn start
  for mem in $MEMS; do
    d="$(cell_dir "$mem")"; fn="$(fn_name "$mem")"
    [[ -f "$d/start_ms.txt" ]] || { log "no start time for $fn, skipping"; continue; }
    start="$(cat "$d/start_ms.txt")"
    log "collecting $fn (waiting 30 s for log delivery)"; sleep 30
    "${AWS[@]}" logs filter-log-events --log-group-name "/aws/lambda/$fn" --start-time "$start" \
      --filter-pattern '{ $.hayaoki = "cold_start" }' --output json > "$d/.cs.json"
    "${AWS[@]}" logs filter-log-events --log-group-name "/aws/lambda/$fn" --start-time "$start" \
      --filter-pattern '"REPORT RequestId"' --output json > "$d/.report.json"
    # one CloudWatch-shaped document: hayaoki lines plus REPORT lines (Init Duration)
    jq -s '{events: (map(.events) | add)}' "$d/.cs.json" "$d/.report.json" > "$d/cold_start.json"
    rm -f "$d/.cs.json" "$d/.report.json"
    local lines inits
    lines="$(jq '[.events[].message | select(contains("\"hayaoki\":\"cold_start\""))] | length' "$d/cold_start.json")"
    inits="$(jq '[.events[].message | select(contains("Init Duration"))] | length' "$d/cold_start.json")"
    log "$fn: invokes=$(count_lines "$d/samples.csv") cold_start lines=$lines REPORT lines with Init Duration=$inits"
    echo "cold_start_lines=$lines init_reports=$inits invokes=$(count_lines "$d/samples.csv")" >> "$d/config.txt"
    make_shareable "$d" "$d/cold_start.json"
    cat "$d/shareable/report.txt"
  done
}

if [[ $COLLECT_ONLY == 1 ]]; then collect; exit 0; fi

if [[ "$BUILDER" == cloudbuild ]]; then
  command -v crane >/dev/null || die "crane not found (brew install crane)"
  ar_note=" plus (cloudbuild builder) Artifact Registry repo '$REPO' and Cloud Build in the GCP project above"
fi
confirm "Create/modify in this AWS account: private ECR repo '$REPO', IAM role '$ROLE' (AWSLambdaBasicExecutionRole only), Lambda functions for memories [$MEMS], log groups; no public endpoints${ar_note:-}. Continue?"
maybe_background "$(cell_dir "$FIRST_MEM")/run.log" "${ORIG_ARGS[@]}"

# --- ECR + build ---
"${AWS[@]}" ecr describe-repositories --repository-names "$REPO" >/dev/null 2>&1 || \
  "${AWS[@]}" ecr create-repository --repository-name "$REPO" --image-scanning-configuration scanOnPush=false >/dev/null
ecr_keep_latest "$REPO"

ecr_image_exists() { "${AWS[@]}" ecr describe-images --repository-name "$REPO" --image-ids imageTag="$APP" >/dev/null 2>&1; }
if [[ $SKIP_BUILD == 0 && -f "$(cell_dir "$FIRST_MEM")/start_ms.txt" ]] && ecr_image_exists; then
  log "resuming: image already in ECR, skipping build"; SKIP_BUILD=1
fi

if [[ $SKIP_BUILD == 0 ]]; then
  ctx="$CLOUD_DIR/results/.build-lambda-$APP"
  prepare_context "$APP" lambda "$ctx"
  tgt="$([[ $APP == redmine ]] && echo lambda || true)"
  if [[ "$BUILDER" == cloudbuild ]]; then
    "${GC[@]}" artifacts repositories describe "$REPO" --location "$GCP_REGION_FIXED" >/dev/null 2>&1 || \
      "${GC[@]}" artifacts repositories create "$REPO" --repository-format docker --location "$GCP_REGION_FIXED" \
        --description "hayaoki bench images (delete with teardown.sh)"
    ar_keep_latest "$REPO" "$GCP_REGION_FIXED"
    mirror_lwa_to_ar "$GCP_REGION_FIXED-docker.pkg.dev/$PROJECT/$REPO/${LWA_PUBLIC_IMAGE##*/}" "$ctx"
    build_with_cloud_build "$AR_IMAGE" "$ctx" "$tgt"
    copy_ar_to_ecr "$AR_IMAGE" "$IMAGE"
  else
    "${AWS[@]}" ecr get-login-password | docker login --username AWS --password-stdin "$ECR_HOST"
    # --provenance=false: Lambda rejects the OCI index that buildx adds by default.
    docker build --platform linux/amd64 --provenance=false ${tgt:+--target "$tgt"} -t "$IMAGE" "$ctx"
    docker push "$IMAGE"
  fi
fi

# --- role (basic logging only) ---
if ! "${AWS[@]}" iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  "${AWS[@]}" iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  "${AWS[@]}" iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  log "waiting for IAM propagation"; sleep 15
fi
ROLE_ARN="$("${AWS[@]}" iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

env_json() { # nonce
  local extra=""
  [[ $ASYNC_INIT == 1 ]] && extra=',"AWS_LWA_ASYNC_INIT":"true"'
  printf '{"Variables":{"SECRET_KEY_BASE":"%s","HAYAOKI_BENCH_NONCE":"%s"%s}}' "$SKB" "$1" "$extra"
}

# assert_private FN: no Function URL and no resource-based policy may exist.
assert_private() {
  local fn="$1" out
  if out="$("${AWS[@]}" lambda get-function-url-config --function-name "$fn" 2>&1)"; then
    die "$fn has a Function URL; delete it and stop"
  fi
  [[ "$out" == *ResourceNotFoundException* ]] || die "unexpected get-function-url-config result for $fn: $out"
  if out="$("${AWS[@]}" lambda get-policy --function-name "$fn" 2>&1)"; then
    die "$fn has a resource-based policy; review and remove it, then stop"
  fi
  [[ "$out" == *ResourceNotFoundException* ]] || die "unexpected get-policy result for $fn: $out"
}

for mem in $MEMS; do
  fn="$(fn_name "$mem")"; write_config "$mem"
  "${AWS[@]}" logs create-log-group --log-group-name "/aws/lambda/$fn" 2>/dev/null || true
  "${AWS[@]}" logs put-retention-policy --log-group-name "/aws/lambda/$fn" --retention-in-days 7
  if "${AWS[@]}" lambda get-function --function-name "$fn" >/dev/null 2>&1; then
    "${AWS[@]}" lambda update-function-code --function-name "$fn" --image-uri "$IMAGE" >/dev/null
    "${AWS[@]}" lambda wait function-updated-v2 --function-name "$fn"
    "${AWS[@]}" lambda update-function-configuration --function-name "$fn" --memory-size "$mem" \
      --timeout 60 --environment "$(env_json 0)" >/dev/null
  else
    for try in 1 2 3 4 5 6; do
      "${AWS[@]}" lambda create-function --function-name "$fn" --package-type Image --code "ImageUri=$IMAGE" \
        --role "$ROLE_ARN" --architectures x86_64 --memory-size "$mem" --timeout 60 \
        --environment "$(env_json 0)" >/dev/null && break
      [[ $try == 6 ]] && die "create-function failed"; log "retrying create-function ($try)"; sleep 10
    done
  fi
  "${AWS[@]}" lambda wait function-active-v2 --function-name "$fn"
  "${AWS[@]}" lambda wait function-updated-v2 --function-name "$fn"
  [[ -f "$(cell_dir "$mem")/start_ms.txt" ]] || echo $(( $(date +%s) * 1000 )) > "$(cell_dir "$mem")/start_ms.txt"
  assert_private "$fn"
done
# Only after every function points at the new image (wait function-updated-v2 above).
ecr_prune_untagged "$REPO"
if [[ "$BUILDER" == cloudbuild ]]; then ar_prune_untagged "${AR_IMAGE%:*}"; fi

# invoke_one MEM INDEX: direct invoke; the response log tail tells cold (Init Duration) from warm.
invoke_one() {
  local mem="$1" i="$2" fn d t0 t1 status kind tail
  fn="$(fn_name "$mem")"; d="$(cell_dir "$mem")"
  t0="$(now_s)"
  "${AWS[@]}" lambda invoke --function-name "$fn" --cli-binary-format raw-in-base64-out \
    --payload "fileb://$EVENT" --log-type Tail --cli-read-timeout 120 "$d/.resp.json" > "$d/.invoke.json"
  t1="$(now_s)"
  status="$(jq -r '.statusCode // "none"' "$d/.resp.json" 2>/dev/null || echo bad)"
  tail="$(jq -r '.LogResult // ""' "$d/.invoke.json" | base64 -d 2>/dev/null || true)"
  # cold: Init Duration in REPORT. proactive: no Init Duration but this invoke logged the hayaoki line
  # (init ran before the request). warm: neither. The 4 KB log tail can miss the line; collect() has the final counts.
  if [[ "$tail" == *"Init Duration"* ]]; then kind=cold
  elif [[ "$tail" == *'"hayaoki":"cold_start"'* ]]; then kind=proactive
  else kind=warm; fi
  echo "$i,$([[ $FORCE == 1 ]] && echo force || echo natural),$(date -u +%Y-%m-%dT%H:%M:%SZ),$status,$kind,$(diff_s "$t0" "$t1")" >> "$d/samples.csv"
  log "$fn sample $i: statusCode=$status $kind (client wall time includes aws CLI overhead)"
  [[ "$kind" == warm ]] && log "  warm hit: no new cold start was produced for this sample"
  return 0
}

done_n="$(count_lines "$(cell_dir "$FIRST_MEM")/samples.csv")"
for ((i = done_n; i < N; i++)); do
  if [[ $FORCE == 1 ]]; then
    # A changed env var discards existing execution environments, so the next invoke is a fresh one.
    for mem in $MEMS; do
      fn="$(fn_name "$mem")"
      "${AWS[@]}" lambda update-function-configuration --function-name "$fn" --environment "$(env_json "n$i-$RANDOM")" >/dev/null
      "${AWS[@]}" lambda wait function-updated-v2 --function-name "$fn"
      invoke_one "$mem" "$i"
    done
  else
    # Natural: wait for Lambda to reclaim idle environments (idle time is undocumented, typically 5-15+ min).
    log "round $i: idling $INTERVAL min"
    wait_minutes "$INTERVAL"
    for mem in $MEMS; do invoke_one "$mem" "$i"; done
  fi
done
collect
