#!/usr/bin/env bash
# Deploy an example image to a PRIVATE Cloud Run service, sample cold starts, collect hayaoki
# cold_start log lines, run `hayaoki cold-start-report`. Teardown: teardown.sh.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
ORIG_ARGS=("$@")

usage() {
  cat >&2 <<USAGE
usage: cloud_run.sh --project ID --expect-project ID --gcloud-config NAME --app minimal|redmine [options]
  (--expect-project may be replaced by gcp_project= in results/.target)
  --samples N        cold starts to sample (default 6)
  --interval-min M   idle minutes before each request in natural mode (default 20)
  --force-cold       smoke-test mode: new revision per sample (see README caveats)
  --collect-only     skip deploy/sampling; just collect logs and report
  --background       confirm now, then continue under nohup (log: results/cloud_run-APP/run.log)
  --yes              skip confirmations (the --background child uses it)
Resumable: re-running continues from results/cloud_run-APP/samples.csv and skips build/deploy when
the image and service already exist.
USAGE
  exit 2
}

PROJECT="" EXPECT="" GCONF="" APP="" N=6 INTERVAL=20 FORCE=0 COLLECT_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --expect-project) EXPECT="$2"; shift 2 ;;
    --gcloud-config) GCONF="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --samples) N="$2"; shift 2 ;;
    --interval-min) INTERVAL="$2"; shift 2 ;;
    --force-cold) FORCE=1; shift ;;
    --collect-only) COLLECT_ONLY=1; shift ;;
    --background) BACKGROUND=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) usage ;;
  esac
done
[[ "$APP" == minimal || "$APP" == redmine ]] || usage
gcp_setup "$GCONF" "$PROJECT" "$EXPECT"

REGION="$GCP_REGION_FIXED"
SERVICE="$BENCH_PREFIX-$APP"
REPO="$BENCH_PREFIX"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/$REPO/$APP:v1"
OUT="$CLOUD_DIR/results/cloud_run-$APP"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"       # index,mode,sent_at,http_code,ttfb_s,total_s

CPU=1 MEMORY=1Gi CONC=8 MAXI=1
{
  echo "platform=cloud_run service=$SERVICE region=$REGION app=$APP cpu=$CPU memory=$MEMORY"
  echo "startup_cpu_boost=on min_instances=0 max_instances=$MAXI concurrency=$CONC ingress=all auth=IAM(no allUsers)"
  echo "mode=$([[ $FORCE == 1 ]] && echo force-cold || echo "natural interval_min=$INTERVAL") samples=$N"
} > "$OUT/config.txt"

# Aborts if the service is public or its invoker IAM check is disabled.
check_private() {
  local pol svc
  pol="$("${GC[@]}" run services get-iam-policy "$SERVICE" --region "$REGION" --format=json)"
  if grep -Eq 'allUsers|allAuthenticatedUsers' <<<"$pol"; then
    die "service $SERVICE has a public IAM binding; remove it and stop"
  fi
  svc="$("${GC[@]}" run services describe "$SERVICE" --region "$REGION" --format=json)"
  if grep -Eq 'invoker-iam-disabled|invokerIamDisabled' <<<"$svc"; then
    die "service $SERVICE has the invoker IAM check disabled; fix it and stop"
  fi
}

collect() {
  local start; start="$(cat "$OUT/start.txt")"
  log "collecting logs (waiting 60 s for ingestion)"; sleep 60
  "${GC[@]}" logging read \
    "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\" AND jsonPayload.hayaoki=\"cold_start\" AND timestamp>=\"$start\"" \
    --format=json --order=asc --limit=1000 > "$OUT/cold_start.json"
  local lines sent
  lines="$(jq length "$OUT/cold_start.json")"; sent="$(count_lines "$CSV")"
  log "requests sent: $sent, cold_start lines: $lines (requests without a line were served by a warm instance)"
  echo "requests_sent=$sent cold_start_lines=$lines" >> "$OUT/config.txt"
  make_shareable "$OUT" "$OUT/cold_start.json"
  cat "$OUT/shareable/report.txt"
  echo "results: $OUT (shareable copy in $OUT/shareable)"
}

if [[ $COLLECT_ONLY == 1 ]]; then collect; exit 0; fi

# APIs: ask in the foreground, before any background hand-off.
enabled="$("${GC[@]}" services list --enabled --format='value(config.name)')"
missing=()
for api in run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com logging.googleapis.com; do
  grep -qx "$api" <<<"$enabled" || missing+=("$api")
done
if ((${#missing[@]})); then
  confirm "Enable APIs: ${missing[*]}?"
  "${GC[@]}" services enable "${missing[@]}"
fi

confirm "Create/modify in project $PROJECT: Artifact Registry repo '$REPO', Cloud Build, PRIVATE Cloud Run service '$SERVICE', IAM invoker binding for $GCP_ACCOUNT only. Continue?"
maybe_background "$OUT/run.log" "${ORIG_ARGS[@]}"

"${GC[@]}" artifacts repositories describe "$REPO" --location "$REGION" >/dev/null 2>&1 || \
  "${GC[@]}" artifacts repositories create "$REPO" --repository-format docker --location "$REGION" \
    --description "hayaoki bench images (delete with teardown.sh)"

image_exists() { "${GC[@]}" artifacts docker images describe "$IMAGE" >/dev/null 2>&1; }
service_exists() { "${GC[@]}" run services describe "$SERVICE" --region "$REGION" >/dev/null 2>&1; }

if [[ -f "$OUT/start.txt" ]] && image_exists && service_exists; then
  log "resuming: image and service exist, skipping build and deploy"
else
  if ! image_exists || [[ ! -f "$OUT/start.txt" ]]; then
    ctx="$OUT/context"
    prepare_context "$APP" cloud_run "$ctx"
    build_with_cloud_build "$IMAGE" "$ctx" "$([[ $APP == redmine ]] && echo cloud_run || true)"
  fi
  [[ -f "$OUT/secret_key_base" ]] || openssl rand -hex 64 > "$OUT/secret_key_base"
  # HAYAOKI_BENCH_SAMPLE only exists to create a new revision in --force-cold mode.
  # --no-allow-unauthenticated: no allUsers binding is created. --ingress all because the caller is a laptop
  # outside GCP (--ingress internal only admits VPC/GCP traffic); IAM still rejects unauthenticated requests.
  "${GC[@]}" run deploy "$SERVICE" --image "$IMAGE" --region "$REGION" \
    --no-allow-unauthenticated --ingress all \
    --cpu "$CPU" --memory "$MEMORY" --cpu-boost \
    --min-instances 0 --max-instances "$MAXI" --concurrency "$CONC" --port 8080 --timeout 60 \
    --set-env-vars "SECRET_KEY_BASE=$(cat "$OUT/secret_key_base"),HAYAOKI_BENCH_SAMPLE=0"
  [[ -f "$OUT/start.txt" ]] || date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/start.txt"
fi

# Only the invoking user gets roles/run.invoker.
"${GC[@]}" run services add-iam-policy-binding "$SERVICE" --region "$REGION" \
  --member "user:$GCP_ACCOUNT" --role roles/run.invoker >/dev/null
check_private

URL="$("${GC[@]}" run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')"
log "service URL: (private; requests need an identity token)"

# A user's `gcloud auth print-identity-token` has no custom audience; Cloud Run accepts it for developers.
request() {
  local i="$1" tok out
  tok="$(gcloud auth print-identity-token)"
  out="$(curl -sS -o /dev/null -w '%{http_code},%{time_starttransfer},%{time_total}' \
    -H "Authorization: Bearer $tok" "$URL/" || echo "000,0,0")"
  echo "$i,$([[ $FORCE == 1 ]] && echo force || echo natural),$(date -u +%Y-%m-%dT%H:%M:%SZ),$out" >> "$CSV"
  log "sample $i: http,ttfb,total = $out"
}

done_n="$(count_lines "$CSV")"
for ((i = done_n; i < N; i++)); do
  if [[ $FORCE == 1 ]]; then
    # New revision per sample. The deploy-time startup check may start the instance that serves this
    # request, so first_response can include idle time; ready_ms is still a valid boot sample.
    "${GC[@]}" run services update "$SERVICE" --region "$REGION" --update-env-vars "HAYAOKI_BENCH_SAMPLE=$((i + 1))" --quiet
    request "$i"
  else
    # Natural: Cloud Run scales an idle instance to zero after about 15 min (not guaranteed).
    log "sample $i: idling $INTERVAL min"
    wait_minutes "$INTERVAL"
    request "$i"
  fi
done
collect
