#!/usr/bin/env bash
# Deletes everything the bench scripts created (names start with hayaoki-bench), then verifies nothing remains.
# Each side needs its own explicit account args. Cloud Logging entries cannot be deleted individually; they
# expire by retention.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat >&2 <<USAGE
usage: teardown.sh [--aws-profile NAME --expect-account 12DIGITS] [--project ID --expect-project ID --gcloud-config NAME] [--yes]
  at least one side; --expect-* may be replaced by results/.target
USAGE
  exit 2
}
PROFILE="" EXPECT_ACCOUNT="" PROJECT="" EXPECT_PROJECT="" GCONF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-profile) PROFILE="$2"; shift 2 ;;
    --expect-account) EXPECT_ACCOUNT="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --expect-project) EXPECT_PROJECT="$2"; shift 2 ;;
    --gcloud-config) GCONF="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$PROFILE" || -n "$PROJECT" || -n "$GCONF" ]] || usage
LEFT=()

if [[ -n "$PROFILE" ]]; then
  aws_setup "$PROFILE" "$EXPECT_ACCOUNT"
  ROLE="$BENCH_PREFIX-lambda-role"
  fns="$("${AWS[@]}" lambda list-functions --query "Functions[?starts_with(FunctionName, '$BENCH_PREFIX-')].FunctionName" --output text)"
  lgs="$("${AWS[@]}" logs describe-log-groups --log-group-name-prefix "/aws/lambda/$BENCH_PREFIX-" --query 'logGroups[].logGroupName' --output text)"
  echo "AWS: functions [${fns:-none}], log groups [${lgs:-none}], role $ROLE, ECR repo $BENCH_PREFIX (with images)" >&2
  confirm "Delete these in the AWS account above?"
  for fn in $fns; do "${AWS[@]}" lambda delete-function --function-name "$fn"; done
  for lg in $lgs; do
    "${AWS[@]}" logs delete-log-group --log-group-name "$lg"
  done
  if "${AWS[@]}" iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    "${AWS[@]}" iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    "${AWS[@]}" iam delete-role --role-name "$ROLE"
  fi
  if "${AWS[@]}" ecr describe-repositories --repository-names "$BENCH_PREFIX" >/dev/null 2>&1; then
    "${AWS[@]}" ecr delete-repository --repository-name "$BENCH_PREFIX" --force >/dev/null
  fi
  # verify
  [[ -z "$("${AWS[@]}" lambda list-functions --query "Functions[?starts_with(FunctionName, '$BENCH_PREFIX-')].FunctionName" --output text)" ]] || LEFT+=("aws: lambda functions")
  [[ -z "$("${AWS[@]}" logs describe-log-groups --log-group-name-prefix "/aws/lambda/$BENCH_PREFIX-" --query 'logGroups[].logGroupName' --output text)" ]] || LEFT+=("aws: log groups")
  ! "${AWS[@]}" iam get-role --role-name "$ROLE" >/dev/null 2>&1 || LEFT+=("aws: iam role")
  ! "${AWS[@]}" ecr describe-repositories --repository-names "$BENCH_PREFIX" >/dev/null 2>&1 || LEFT+=("aws: ecr repo")
fi

if [[ -n "$PROJECT" || -n "$GCONF" ]]; then
  gcp_setup "$GCONF" "$PROJECT" "$EXPECT_PROJECT"
  list_svcs() { "${GC[@]}" run services list --region "$GCP_REGION_FIXED" --format='value(metadata.name)' | { grep "^$BENCH_PREFIX-" || true; }; }
  svcs="$(list_svcs)"
  buckets="$("${GC[@]}" storage ls | { grep -E "_cloudbuild/?$" || true; })"
  echo "GCP: Cloud Run services [${svcs:-none}], Artifact Registry repo $BENCH_PREFIX (with images), Cloud Build source objects in [${buckets:-no bucket}] under source/" >&2
  confirm "Delete these in the GCP project above?"
  for s in $svcs; do "${GC[@]}" run services delete "$s" --region "$GCP_REGION_FIXED" --quiet; done
  if "${GC[@]}" artifacts repositories describe "$BENCH_PREFIX" --location "$GCP_REGION_FIXED" >/dev/null 2>&1; then
    "${GC[@]}" artifacts repositories delete "$BENCH_PREFIX" --location "$GCP_REGION_FIXED" --quiet
  fi
  for b in $buckets; do
    if "${GC[@]}" storage ls "${b%/}/source/" >/dev/null 2>&1; then "${GC[@]}" storage rm -r "${b%/}/source/"; fi
  done
  [[ -z "$(list_svcs)" ]] || LEFT+=("gcp: cloud run services")
  ! "${GC[@]}" artifacts repositories describe "$BENCH_PREFIX" --location "$GCP_REGION_FIXED" >/dev/null 2>&1 || LEFT+=("gcp: artifact registry repo")
  log "GCP: API enablement and the Cloud Build bucket itself are left as they were"
fi

if ((${#LEFT[@]})); then
  die "teardown incomplete, still present: ${LEFT[*]}"
fi
log "teardown complete; verified nothing named $BENCH_PREFIX remains on the targeted side(s)"
