# Deployment examples

Templates for running a Rails app on Cloud Run and on AWS Lambda with the in-situ cold-start recorder (`hayaoki/insitu`) enabled. They are not part of the gem. CI builds both images and runs them locally (`.github/workflows/templates.yml`); it does not deploy them, and the cloud-side settings have not been tried on real deployments yet.

These files do not make boot faster by being installed. They set the platform options that affect cold starts, and the recorder shows what each one changed.

| Path | Contents |
| --- | --- |
| [`puma.rb`](puma.rb) | Puma in single mode: threads from `RAILS_MAX_THREADS`, bound to `PORT` |
| [`cloud_run/`](cloud_run/) | `Dockerfile`, `service.yaml` (Knative service) |
| [`lambda_lwa/`](lambda_lwa/) | `Dockerfile` (Lambda Web Adapter), `template.yaml` (SAM) |

The Dockerfiles follow the one that `rails new` generates in Rails 7.1+, with these cold-start-related points:

- `bootsnap precompile --gemfile` and `bootsnap precompile app/ lib/` at build time. Without them the first boot builds the cache. `hayaoki boot-report --bootsnap cold` shows what that costs.
- `RAILS_ENV=production`, `WEB_CONCURRENCY=0` (Puma single mode), `RAILS_MAX_THREADS` set explicitly, logs to stdout.
- A `/up` route. Rails 7.1+ has `rails/health#show`; on 7.0 add `get "up" => proc { [200, {}, ["ok"]] }` to `config/routes.rb`.

There is no `rails-app/` directory: CI generates the test app with `rails new --minimal` (Rails 8.0.2).

## Add the recorder to your app

```ruby
# Gemfile
gem "hayaoki", require: false

# config/boot.rb
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "hayaoki/insitu"   # before bootsnap/setup, so its cost is counted
require "bootsnap/setup"
```

With `RAILS_ENV=production` it is on by default. It writes one JSON line per process to stdout after the first non-probe response. See the [README](../README.md#in-situ-cold-start-logging) and [docs/design/phase2.md](../docs/design/phase2.md) for the fields and limits.

## Secrets

Do not copy `config/master.key` into the image (Rails' default `.dockerignore` excludes it). The images run as a non-root user and could not read a root-owned key anyway. Pass `RAILS_MASTER_KEY` or `SECRET_KEY_BASE` as an environment variable or a secret.

## Platform facts the templates rely on

Checked against the vendor docs on 2026-11-08.

- Lambda Init is limited to 10 s, and is billed for all functions since 2025-08-01. SnapStart and Lambda Managed Instances do not support Ruby. [L1, L2, L3, L4]
- Cloud Run startup CPU boost gives 2x the vCPU limit during startup and for 10 s after. An HTTP startup probe passes on any 2xx or 3xx response. [C2, C3]

Sources:

- [L1] https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html
- [L2] https://aws.amazon.com/blogs/compute/aws-lambda-standardizes-billing-for-init-phase/
- [L3] https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html
- [L4] https://docs.aws.amazon.com/lambda/latest/dg/lambda-managed-instances-runtimes.html
- [L6] https://github.com/aws/aws-lambda-web-adapter
- [L7] https://aws.github.io/aws-lambda-web-adapter/configuration/readiness-check.html
- [C1] https://docs.cloud.google.com/run/docs/container-contract
- [C2] https://docs.cloud.google.com/run/docs/configuring/healthchecks
- [C3] https://docs.cloud.google.com/run/docs/configuring/cpu

Not verified: the metric name `run.googleapis.com/container/startup_latencies` (seen only in third-party docs), and the Lambda variables `AWS_LAMBDA_INITIALIZATION_TYPE` and `AWS_LAMBDA_LOG_STREAM_NAME` that the recorder reads (`init_type`, `log_stream`).
