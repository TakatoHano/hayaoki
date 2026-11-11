# bench/cloud: cold-start measurements on Cloud Run and Lambda

Scripts for the Phase 2 validation plan (`docs/design/phase2.md` section 6). They deploy the example images to
private services, produce cold starts, collect the `hayaoki` `cold_start` log lines and run
`hayaoki cold-start-report`. Nothing here has been run against real accounts yet.

| File | Role |
| --- | --- |
| `common.sh` | argument checks, account printing, y/N confirm, masking, Cloud Build helper |
| `cloud_run.sh` | build, deploy a private Cloud Run service, sample, collect, report |
| `lambda.sh` | build, push to private ECR, create one function per memory size, sample, collect, report |
| `teardown.sh` | delete everything the scripts created |
| `apps/gen_minimal.sh` | `rails new --minimal` app as in `.github/workflows/templates.yml`, with `hayaoki` 0.4.3 from rubygems |
| `apps/redmine/Dockerfile` | Redmine 7.0, SQLite migrated at build, `hayaoki` added; targets `cloud_run` and `lambda` |

## Prerequisites on your machine

- `gcloud`, `aws` (v2), `jq`, `perl`, `curl`, `openssl`, `ruby` (to run `exe/hayaoki` from this checkout).
- Cloud Run: builds run in Cloud Build, so no local docker is needed. The scripts ask before enabling the APIs
  `run`, `cloudbuild`, `artifactregistry` and `logging`.
- Lambda: local docker (`--platform linux/amd64`), or `--builder cloudbuild`: Cloud Build pushes only to a private
  Artifact Registry repo, then `crane copy` (run locally) copies the image to ECR. Passwords go to `crane auth login`
  through stdin only; no AWS credential is given to Cloud Build. Needs `crane` (`brew install crane`).
  The Lambda Web Adapter image is first copied locally with crane into the same private AR repo (Cloud Build's
  anonymous pulls from public.ecr.aws can hit rate limits); teardown removes it with the repo.
- Minimal app generation needs `rails` 8.0.2 locally, or docker (falls back to a `ruby:3.4.7-slim` container).

## Privacy

- Cloud Run: `--no-allow-unauthenticated`; the script never adds `allUsers` or `allAuthenticatedUsers`, and checks the
  IAM policy after deploy (aborts if either appears). Only the active gcloud user gets `roles/run.invoker`. Requests carry
  `Authorization: Bearer $(gcloud auth print-identity-token)`; Cloud Run accepts a user ID token without a custom
  audience for developers (https://docs.cloud.google.com/run/docs/authenticating/developers), so `--audiences` is not used.
  Ingress stays `all` because the caller is a laptop outside GCP (`--ingress internal` only admits VPC/GCP traffic);
  IAM rejects every unauthenticated request.
- Lambda: no Function URL, no API Gateway. Functions are called with `aws lambda invoke` and an API Gateway HTTP API v2 /
  Function URL shaped event (GET `/`). The role has only `AWSLambdaBasicExecutionRole`. The ECR repo is private.
- Account scoping: `--profile` / `--project` / `--gcloud-config` are required (no defaults), region is fixed
  (`ap-northeast-1`, `asia-northeast1`). `--expect-account <12 digits>` (AWS) and `--expect-project <id>` (GCP) are
  required too (or `aws_account=...` / `gcp_project=...` lines in the gitignored `results/.target`); the script dies
  unless sts / gcloud agree, and `--project` must equal the gcloud configuration's project. Each script prints the
  target identity and asks y/N before creating anything (`--yes` skips it; `--background` confirms first, then re-runs
  itself under nohup with the log in `results/<cell>/run.log`).
- After deploy, `lambda.sh` asserts that `get-function-url-config` and `get-policy` return ResourceNotFound, and
  `cloud_run.sh` asserts no public binding and no disabled invoker IAM check. The trust policy is the plain Lambda one
  (an `aws:SourceAccount` condition was not added: not confirmed as supported for Lambda execution roles).
- Sharing: raw output stays in `results/` (gitignored). `results/<cell>/shareable/` has the log lines, config and
  reports with the account ID, project ID and number, account email, profile, `run.app` hosts, instance IDs, log stream
  names, ARNs, registry hosts and request IDs replaced by placeholders. If a leak check still finds something
  (12-digit number, email, SSO role, service account, ARN, registry host) it writes `shareable/.REVIEW_NEEDED` and warns;
  check it before publishing. Do not put real identifiers in committed files.

## Cold-start methods

Default: natural. One request per `--interval-min` (default 20 min), `--samples` rounds (default 6), min instances 0 and
no provisioned concurrency, so the load is a handful of requests. The first Cloud Run wait lets the deploy-time instance
go away. Use `--background` for the long run (do not start it with a plain `nohup ./x.sh &`: the confirmation needs the
terminal). It is resumable: re-run the same command to continue (progress in `results/<cell>/samples.csv`; build and
deploy are skipped when the image and service exist). Logs are read once at the end (`--collect-only` re-collects).

- Cloud Run scales an idle instance to zero after about 15 minutes, not guaranteed. A request that hits a warm instance
  produces no line; the script prints requests sent vs lines found. Only the platform side is private/IAM-protected;
  client wall time is `curl` time_starttransfer.
- Lambda reclaims idle environments after an undocumented time (typically 5 to 15+ minutes). Each invoke's log tail is
  checked: `Init Duration` means `cold`; no Init Duration but the hayaoki line in the same invoke means `proactive`; neither
  means `warm` (the 4 KB log tail can miss the line, so the final counts from CloudWatch are authoritative).
  Client time for Lambda is the `aws lambda invoke` wall time, which includes CLI start-up.
- Lambda may initialize an environment before the request arrives (proactive init); the report's
  `--exclude-proactive` variant (`report_exclude_proactive.txt`) drops those.

`--force-cold` is for smoke tests only. Lambda: an env var change (`HAYAOKI_BENCH_NONCE`) before each invoke, waiting for
`LastUpdateStatus=Successful`. Cloud Run: a new revision per sample (`HAYAOKI_BENCH_SAMPLE`). Caveat: a new Cloud Run
revision starts a startup-check instance that may then serve the request, so `first_response` can include idle time.
Each line still comes from its own process start, so `ready_ms` is a valid boot sample. Do not use forced numbers as
the cold-start figure in the article.

## Configuration recorded

Cloud Run: 1 vCPU, 1Gi, startup CPU boost on, min 0, max 1, concurrency 8, default TCP startup probe. Lambda: 1024 MB and
2048 MB (`--memories`), x86_64, timeout 60 s. Written to `results/<cell>/config.txt`.

## Usage

```sh
# smoke run, N=2, forced (about 10 minutes)
./cloud_run.sh --project example-project --expect-project example-project --gcloud-config example-config \
  --app minimal --samples 2 --force-cold
./lambda.sh --profile example-profile --expect-account 123456789012 --app minimal --samples 2 --force-cold

# real run, natural cold starts (about 2 hours per 6 samples); confirms now, then runs under nohup
./cloud_run.sh --project example-project --expect-project example-project --gcloud-config example-config \
  --app minimal --samples 6 --background
./lambda.sh --profile example-profile --expect-account 123456789012 --app minimal --samples 6 --background

# then tear down
./teardown.sh --aws-profile example-profile --expect-account 123456789012 \
  --project example-project --expect-project example-project --gcloud-config example-config
```

Add `--app redmine` for Redmine. Add `--exec-env gen2` to `cloud_run.sh` to measure the second-generation execution environment; it reuses the image already built for gen1 (implies `--skip-build`) (service `hayaoki-bench-APP-gen2`, results in `results/cloud_run-APP-gen2`). Options: `./cloud_run.sh` and `./lambda.sh` without arguments print usage.

Use a dedicated GCP project and AWS account for this bench. `teardown.sh` deletes the `source/` prefix of the project's `*_cloudbuild` bucket, which would also remove other Cloud Build sources in a shared project.

Images: each app keeps at most one image. After the new image is deployed the scripts delete untagged (replaced) versions; an Artifact Registry cleanup policy (keep the newest version) and an ECR lifecycle rule (expire untagged images after a day) are set as a backstop.

## Rough cost

A handful of requests, small images, 7-day log retention: well under 1 USD per run on each platform (Cloud Build
minutes and Artifact Registry/ECR storage are the main items; Redmine builds take longer). Teardown removes the repos.

## Not verified

- Redmine on Lambda: boot may exceed the 10 s Init limit. Then Lambda re-runs init inside the first invoke, and the
  invoke includes the boot (no `Init Duration` is reported for it). `lambda.sh --async-init` sets `AWS_LWA_ASYNC_INIT=true`:
  LWA finishes Init quickly and the first request waits for the app, so `Init Duration` shrinks and invoke duration grows.
  The hayaoki `ready_ms` is unaffected, but compare platform init numbers only between runs with the same setting.
- Lambda Web Adapter accepting a raw `aws lambda invoke` event of this shape (its README lists API Gateway, Function URL
  and ALB as sources; the smoke run confirms).
- `cold-start-report` reading the merged CloudWatch document (hayaoki plus REPORT lines).
- The Redmine images (read-only file system handling on Lambda, `Gemfile.local`, `config/boot.rb` edit).
- Cloud Run `K_REVISION` grouping and `roles/run.invoker` needs for your user.
