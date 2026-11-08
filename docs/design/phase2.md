# Phase 2 design: in-situ cold-start logging and serverless templates

Status: draft (2026-11-08). Target release: hayaoki 0.2.0.

Phase 1 (`hayaoki boot-report`) measures boot in a lab: child processes on a dev box or CI runner. Phase 2 measures **real cold starts in production** and ships **deployment templates** for Cloud Run and Lambda, so the article can show numbers from both the lab and the platform.

As in Phase 1, nothing here makes boot faster by being installed. The templates set the platform options that matter (CPU boost, probes, precompiled bootsnap), and the docs say what each one changes.

---

## 0. Decisions at a glance

| # | Decision |
|---|---|
| D1 | v0.2.0 is pure Ruby. No outside-Ruby wrapper. The process start time comes from `/proc/self/stat`. Platform metrics (Lambda `Init Duration`, Cloud Run `container/startup_latencies`) cover the time before exec. |
| D2 | Entry point: `require "hayaoki/insitu"` in `config/boot.rb`, right after `require "bundler/setup"`. In the Gemfile: `gem "hayaoki", require: false`. No Kernel#require tracing. Only coarse phase hooks (about 5 prepends). |
| D3 | Output: one JSON line per process, written to stdout, after the first non-probe response (fallback: `at_exit`). The line is a bare JSON object so Cloud Logging parses it into `jsonPayload` and CloudWatch Logs Insights can query its fields. |
| D4 | First request: v0.2 records its duration and the files loaded during it (count plus top groups by gem). It does not time individual files. |
| D5 | Templates go in `examples/` in the repo. They are not packaged in the gem and there is no generator yet. CI builds the images and runs them locally. CI does not deploy. |
| D6 | The Phase 1 probe is not used in production for v0.2. Reused from Phase 1: the JSON encoder (moved to a shared file), the hook patterns (Bundler, `initialize!`, eager_load), and the redaction logic. |
| D7 | Rust or other non-Ruby code is deferred. The only candidate is a Lambda extension that uses the Telemetry API (§1.4). |

---

## 1. What in-situ logging measures

### 1.1 Timeline and who can see each point

| # | Point | Pure Ruby can capture? | How | Notes |
|---|---|---|---|---|
| P0 | Instance scheduled / image pulled / sandbox up | No | Platform only: Lambda `Init Duration` (REPORT line); Cloud Run `run.googleapis.com/container/startup_latencies` | A wrapper cannot see this either: it also starts at exec. |
| P1 | Process exec | Yes (Linux) | `/proc/self/stat` field 22 `starttime` (clock ticks since boot) compared with `Process.clock_gettime(CLOCK_BOOTTIME)` | Resolution is 1/`CLK_TCK`, usually 10 ms. `exec` keeps the pid and starttime, so `sh -c "exec bundle exec puma"` measures from the shell's start. |
| P2 | Ruby VM up | Partly | `CLOCK_PROCESS_CPUTIME_ID` when hayaoki loads (a hint, as in Phase 1 `cpu0_us`) | Cannot be separated from P1→P3 without a wrapper. Typically 30–60 ms. |
| P3 | hayaoki loaded (after `bundler/setup`) | Yes | `CLOCK_BOOTTIME` at load | P1→P3 = VM boot + RubyGems + bundler/setup. |
| P4 | `Bundler.require` start/end | Yes | prepend `Bundler::Runtime#require` (same as probe `BundlerHook`) | P3→P4 includes `require "rails/all"` and `bootsnap/setup`. |
| P5 | `Rails::Application#initialize!` start/end | Yes | prepend `Rails::Application` (probe `AppHook`), installed when P4 starts (by then Rails is loaded) | |
| P5e | eager_load (inside P5) | Yes | Same hooks as probe H9/H9b: `Zeitwerk::Loader#eager_load` plus each `eager_load_namespaces` member's `eager_load!`. Durations are summed; the top 5 namespaces are kept. | This is where TZInfo, I18n and AbstractController show up. |
| P6 | Server listening / platform says ready | Indirectly | Time of the first request to an ignored health path (`/up`, `AWS_LWA_READINESS_CHECK_PATH`) = `first_probe`. If there is none, `ready := initialize_end` with `ready_source: "initialize"`. | A Puma plugin would give the exact listen time. Deferred (§7). |
| P7 | First real request received | Yes | Rack middleware at position 0 | Health paths are excluded. |
| P8 | First response sent | Yes | `Rack::BodyProxy` close of that response | This includes body streaming time. It does not include network time to the client. |

Platform facts this relies on (verified 2026-11-08):

- Lambda Init is limited to **10 s**. If Init takes longer, it is retried during the first invoke under the function timeout. The 10 s limit does not apply to provisioned concurrency, SnapStart, or Managed Instances. [L1]
- Since 2025-08-01, Lambda Init is **billed** for all functions. [L2]
- A successful Init emits no `INIT_REPORT` line (except with SnapStart or provisioned concurrency). `Init Duration` appears on the first `REPORT` line. [L1]
- Lambda may **initialize ahead of the request** ("proactive init"), which leaves a gap between Init and Invoke. [L1] So `idle_ms = P7 - P6` is logged, and the analyzer separates user-facing cold starts from proactive ones.
- **SnapStart does not support Ruby** (`ruby4.0` is named as unsupported; OS-only runtimes are also unsupported). [L3] **Lambda Managed Instances** support Java, Python, Node.js, .NET and Rust (on `provided.al2023`). They do not support Ruby. [L4]
- Cloud Run sets `K_SERVICE`, `K_REVISION`, `K_CONFIGURATION` and `PORT`. The container must listen within 4 minutes. Requests queue while an instance starts. [C1]
- Cloud Run startup probe defaults: `periodSeconds` 10, `timeoutSeconds` 1, `failureThreshold` 3. The maximum is `failureThreshold × periodSeconds ≤ 600 s`. Without a configured probe, new services get a TCP probe (240 s / 240 s / 1). An HTTP probe passes on any 2xx or 3xx response. [C2]
- Cloud Run startup CPU boost gives 2× the vCPU limit during startup and for 10 s after it (1→2, 2→4, 4→8). The boosted CPU is billed. [C3]

### 1.2 Clocks

- On Linux, all marks use `CLOCK_BOOTTIME`, so they share a time base with `starttime`. Each mark is stored as ms since process start (P1 = 0).
- `start_at` (ISO 8601) = `CLOCK_REALTIME_now - (BOOTTIME_now - start_boottime)`. It is computed once, when the line is emitted.
- Other platforms (macOS, or `/proc` not readable): origin = P3, `start_source: "load"`, and marks before P3 are null.
- To verify: whether `/proc/self/stat` and `CLOCK_BOOTTIME` behave normally under Cloud Run gen1 (gVisor) and Lambda Firecracker. We expect yes. If the values look wrong, record `start_source: "none"`.

### 1.3 Extra cheap facts (read once, at emit time)

`/proc/self/status` VmRSS; `/proc/uptime` (sandbox age, which shows whether the VM booted for this instance); the age of `/proc/1/stat` starttime when pid ≠ 1; `GC.count` and `GC.stat(:time)`; process CPU ms; `$LOADED_FEATURES.size`; `RubyVM::YJIT.enabled?`; whether bootsnap is loaded and whether its cache dir exists; `Rails.application.config.eager_load`; `I18n::Backend::Simple#initialized?` at ready (shows whether I18n loading is deferred to the first `t()`).

### 1.4 Outside-Ruby wrapper: not needed for v1

A wrapper would add only (a) µs-precision exec time instead of 10 ms, (b) the exact listen time without a Puma plugin, and (c) support for non-Linux. None of these is worth the cost. The one non-Ruby component worth building later is a **Lambda extension that subscribes to the Telemetry API** (`platform.initStart`, `platform.initRuntimeDone`, `platform.initReport`) [L5]. It would join the exact platform Init boundaries with our line, using `AWS_LAMBDA_LOG_STREAM_NAME` plus the pid. That is the possible Rust piece (a self-contained binary, as AWS recommends). It is deferred to 0.3+. rbspy and Vernier are for deep profiling and stay out of 0.2.

---

## 2. Integration surface

### 2.1 Install

```ruby
# Gemfile
gem "hayaoki", require: false

# config/boot.rb
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "hayaoki/insitu"   # <- add (before bootsnap/setup so its cost is counted)
require "bootsnap/setup"
```

- Not before `bundler/setup`: RubyGems would activate whatever hayaoki version is installed, which can conflict with the lockfile.
- Also supported: `gem "hayaoki", require: "hayaoki/insitu"`. In that case P4 start is unknown (`bundler_require_start: null`, `entry: "bundler"`). Everything else works.
- Railtie: not used for setup. At P4 start (Rails is loaded by then), insitu prepends `AppHook`, inserts the middleware through a `Rails::Railtie` subclass defined at that point (`initializer "hayaoki.insitu"` → `app.middleware.insert_before 0, Hayaoki::Insitu::Middleware`), and installs the eager-load hooks. If `Bundler.require` is never called, it falls back to doing this at load time if `Rails::Application` is already defined.

### 2.2 Configuration (env vars only in 0.2)

| Var | Default | Meaning |
|---|---|---|
| `HAYAOKI_INSITU` | enabled when `RAILS_ENV`/`RACK_ENV` = production, else off | `0` = off, `1` = force on. When off, the require is a no-op: no prepends, no middleware. |
| `HAYAOKI_INSITU_OUT` | `stdout` | `stdout`, `stderr`, or a file path (append) |
| `HAYAOKI_INSITU_IGNORE_PATHS` | `/up` + `$AWS_LWA_READINESS_CHECK_PATH` | comma separated; these requests set `first_probe` and do not count as the first request |
| `HAYAOKI_INSITU_EMIT` | `first_request` | `first_request`, or `ready` (emit at `initialize_end`; for apps whose first request may never come) |

### 2.3 Overhead budget

| Item | Budget | How we hold it |
|---|---|---|
| Boot | < 2 ms total | 5 prepends, no Kernel hooks, no allocation per require |
| Per request after the first | one ivar check (< 100 ns) | the middleware switches to pass-through after it emits |
| Emit | < 2 ms, line ≤ 4 KB | small encoder, `/proc` reads, `$LOADED_FEATURES` slice |
| Memory | < 100 KB | only the feature-count snapshot (an Integer) and ≤ 20 strings |

Checked by `bench/insitu_overhead.rb` (an A/B run like Phase 1 §8.3). It is a nightly workflow, not a gating test.

### 2.4 Reuse from Phase 1

- Move `Hayaoki::Probe.encode` to `lib/hayaoki/mini_json.rb` (`Hayaoki::MiniJSON.encode`). `probe.rb` `require_relative`s it before it installs its Kernel hooks, so the require is not recorded. This keeps json out of the app process.
- Port the hook patterns (`BundlerHook`, `AppHook`, `EagerLoadHook`, namespace `eager_load!`) into `Hayaoki::Insitu::Hooks`. Do not share them with the probe: the probe needs the `Probe.span` recorder, and insitu needs only start/end stamps.
- The path → `<gem:name>` / `<app>` grouping reuses the logic of `BootReport::Formatters::Redact`. Move its regex to `lib/hayaoki/redact.rb` and keep the old class as a thin wrapper.
- The probe is **not** loaded in production. A future `HAYAOKI_INSITU=trace` (0.3) may load it through `RUBYOPT=-r<abs path>` and emit a top-N gem summary instead of raw events.

---

## 3. Output

### 3.1 Line schema (v1)

```json
{
  "hayaoki": "cold_start", "v": 1, "severity": "INFO",
  "message": "hayaoki cold start: ready 2140ms, first response 2410ms",
  "status": "ok",
  "id": "9f2c1a7e", "pid": 1, "worker": false,
  "start_at": "2026-11-08T03:12:45.120Z", "start_source": "proc_stat",
  "platform": {"kind": "cloud_run", "service": "redmine", "revision": "redmine-00012-abc", "configuration": "redmine"},
  "runtime": {"ruby": "3.4.7", "rails": "8.1.1", "hayaoki": "0.2.0", "yjit": false, "env": "production",
              "bootsnap": true, "bootsnap_cache": true, "eager_load": true, "entry": "boot_rb"},
  "marks_ms": {"loaded": 180, "bundler_require_start": 410, "bundler_require_end": 1020,
               "initialize_start": 1090, "initialize_end": 2120, "first_probe": 2140,
               "first_request_start": 2150, "first_response_end": 2410},
  "phases_ms": {"pre_load": 180, "pre_bundler": 230, "bundler_require": 610, "app_config": 70,
                "initialize": 1030, "eager_load": 640, "to_ready": 2140, "idle": 10,
                "first_request": 260, "to_first_response": 2410},
  "eager_top": [["TZInfo", 206], ["I18n", 180], ["AbstractController", 120]],
  "first_request": {"route": "issues#index", "status": 200, "probe_hits": 1,
                    "new_features": 41, "new_by_group": [["<gem:tzinfo>", 12], ["<app>", 9], ["<stdlib>", 5]],
                    "gc_count": 2},
  "proc": {"cpu_ms": 1850, "rss_kb": 214000, "uptime_ms": 2600, "pid1_age_ms": null,
           "gc_count": 31, "gc_time_ms": 95, "features": 1490, "i18n_loaded": false}
}
```

- `platform.kind`: `cloud_run` (if `K_SERVICE` is set), `lambda` (if `AWS_LAMBDA_FUNCTION_NAME` is set; adds `function`, `version`, `memory_mb`, `init_type` from `AWS_LAMBDA_INITIALIZATION_TYPE`, and `log_stream` from `AWS_LAMBDA_LOG_STREAM_NAME`; these var names are still to be checked against the AWS env-var reference), or `generic`.
- `status`: `ok`; `no_request` (emitted at `at_exit` before any real request); `boot_error` (`initialize!` raised; logs `error_class` only).
- `ready` = `first_probe` when present, else `initialize_end`. `ready_source` tells which.
- `phases_ms` duplicates what can be derived from `marks_ms`, so plain queries in Cloud Logging and Logs Insights work without any math. Null marks produce null phases.
- `id`: 8 random hex characters per process. It joins worker lines from the same boot (`worker: true` when pid ≠ the pid at load, for example Puma cluster workers). One line per serving process.

### 3.2 Redaction (always on in insitu)

- Never logged: query strings, raw paths, headers, env values, exception messages.
- `route` is `controller#action` from `action_dispatch.request.path_parameters`, or null (Q5).
- Feature paths appear only as group counts (`<gem:name>`, `<app>`, `<stdlib>`, `<other>`). No file names.
- The text in `message` is fixed. It contains no user data.

### 3.3 `hayaoki cold-start-report`

```
hayaoki cold-start-report [FILE...]   # default stdin
  --group-by KEY      revision|platform.kind|runtime.ruby|init_type|... (dotted path)
  --since TIME / --until TIME
  --format text|json
  --exclude-proactive  drop lines with idle_ms > 1000 (Lambda proactive init)
```

- Accepted input, line by line: our bare JSON; Cloud Logging export (`gcloud logging read --format=json` → array or JSONL with `jsonPayload`); CloudWatch (`aws logs filter-log-events` JSON, where `message` is a string). Rule: find the first `{"hayaoki":"cold_start"` object, wherever it is nested or embedded. `REPORT ... Init Duration: X ms` lines are counted on their own as `platform_init_ms`.
- Output: n, then p50/p90/p99/max for each `phases_ms` key, the mean `eager_top`, the first-request lazy-load groups, and a split of proactive and user-facing starts. The CLI may require `json` (it runs outside the app).
- Files: `lib/hayaoki/cold_start_report/{reader,stats,formatters/text,formatters/json}.rb`; the CLI command goes in `lib/hayaoki/cli.rb`.

---

## 4. First-request cost

v0.2 records `first_request` (P7→P8), `new_features` (the `$LOADED_FEATURES` delta, grouped), the GC delta, and `i18n_loaded` at ready. This is enough to show lazy cost that moved from boot into the first request: the Phase 1 Redmine data had I18n lazy at −286 ms boot and +317 ms on the first `t()`. The I18n YAML load is not a require, so `i18n_loaded` and `first_request` duration are the signals for it.

Not in v0.2: per-file timing during the first request (it would need the probe), and comparison with warm request latency (use platform metrics).

---

## 5. Templates

### 5.1 What ships (repo `examples/`, not in the gem)

```
examples/
  README.md                      # what each knob does, with sources; "does not make boot faster by itself" note
  rails-app/                     # rails new --minimal 8.x fixture used by CI (or generated in CI, see 5.3)
  cloud_run/
    service.yaml                 # Knative service
    Dockerfile.patch.md          # deltas over the Rails 7.1+ generated Dockerfile
  lambda_lwa/
    Dockerfile.patch.md          # + COPY lambda-adapter, env
    template.yaml                # SAM: PackageType Image, Function URL
  puma.rb                        # single mode, threads from env, bind PORT
```

Shared Dockerfile points. Rails 7.1+ `rails new` already generates most of them, so the templates are deltas:
- `bundle exec bootsnap precompile --gemfile` and `bootsnap precompile app/ lib/` at build time (`hayaoki boot-report --bootsnap cold` shows the cost if this is missing).
- `RAILS_ENV=production`, `WEB_CONCURRENCY=0` (Puma single mode), `RAILS_MAX_THREADS=N`, logs to stdout.
- `/up` route: Rails 7.1+ has `rails/health#show`. On 7.0, add a one-line route.

`cloud_run/service.yaml`:
- `run.googleapis.com/startup-cpu-boost: "true"` [C3]
- `containerConcurrency` = `RAILS_MAX_THREADS` (one Puma process)
- `startupProbe.httpGet.path: /up`, `periodSeconds: 1`, `timeoutSeconds: 1`, `failureThreshold: 60` (60 s budget; documented) [C2]
- `autoscaling.knative.dev/minScale: "0"`, with a comment on `min-instances` as the real fix for latency-critical services
- `HAYAOKI_INSITU` left at its default (production → on)

`lambda_lwa/`:
- `COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter`. Non-Lambda base images (for example the Rails-generated `ruby:*-slim`) work because LWA ships the Runtime Interface Client. [L6]
- `AWS_LWA_PORT=3000` (default 8080), `AWS_LWA_READINESS_CHECK_PATH=/up` (default `/`) [L6, L7]
- `AWS_LWA_ASYNC_INIT=true`, commented, with an explanation: use it when boot can exceed about 9.8 s, so the 10 s Init limit is not hit [L7, L1]
- SAM: `MemorySize: 1769` (1 vCPU), `Timeout: 30`, `FunctionUrlConfig.AuthType: AWS_IAM` (NONE only as a commented option)
- Lamby: mentioned in README as an alternative (Rack adapter on the Ruby base image). No template.
- README states: no SnapStart for Ruby [L3], no Managed Instances for Ruby [L4], and Init is billed [L2].

### 5.2 Why no generator yet

Templates have to be checked against real deployments first (§6), and a generator that writes into user apps has to deal with Rails 7.0 vs 7.1+ Dockerfiles. Revisit `hayaoki templates PLATFORM` in 0.3, once the files are stable.

### 5.3 CI (`.github/workflows/templates.yml`, on push to `examples/**` + `lib/hayaoki/insitu*`)

1. Generate the fixture app (`rails new --minimal`, pinned), add `gem "hayaoki", path: "/hayaoki"` and the boot.rb line, and apply the Dockerfile deltas.
2. `docker build` the Cloud Run variant and the LWA variant. Outside Lambda, `/opt/extensions` is inert, so the image runs as a plain container.
3. `docker run -e K_SERVICE=ci -e K_REVISION=ci-1` (and a Lambda-like env for the second image). Poll `/up`, `GET /`, stop the container, and assert exactly one `"hayaoki":"cold_start"` line with `platform.kind`, a non-null `phases_ms.to_ready`, and `first_request.status`.
4. Pipe the captured lines to `hayaoki cold-start-report --format json` and assert that it parses.
5. Lint: `sam validate --lint` for `template.yaml`, and a Ruby test that loads `service.yaml` and asserts the required keys (no gcloud auth in CI).
6. Deferred: a `workflow_dispatch` deploy job that runs only when `GCP_WIF_PROVIDER` / `AWS_ROLE_ARN` secrets exist.

---

## 6. Validation plan (numbers for the article)

Apps: (1) the `rails new --minimal` fixture (baseline); (2) Redmine 7.0 with SQLite baked into the image at build time (`db:migrate` in the Dockerfile; on Lambda, copy it to `/tmp` or keep it read-only). Mastodon needs Postgres and Redis, so it gets local `docker run` numbers only, unless the user wants to pay for Cloud SQL and Memorystore (Q4).

Protocol (run manually by the user with their accounts; scripts in `bench/cloud/`):
- Force cold starts. Cloud Run: deploy a new revision per sample (`--update-env-vars HAYAOKI_SAMPLE=n`) and send one request. Lambda: `update-function-configuration` with an env bump, wait for `LastUpdateStatus=Successful`, then invoke the Function URL. N = 30 per cell.
- Cells: bootsnap precompiled on/off × CPU boost on/off (Cloud Run) × Lambda memory 1024/1769/3008 × TZInfo eager-load fix on/off. Only one factor changes from the baseline at a time.
- For each sample, record (a) our line, (b) platform init (`Init Duration` / `startup_latencies`), and (c) client time to first byte (`curl -w %{time_starttransfer}` from the same region).
- Collect with `gcloud logging read 'jsonPayload.hayaoki="cold_start"' --format=json` / `aws logs filter-log-events --filter-pattern '{ $.hayaoki = "cold_start" }'`, then run `hayaoki cold-start-report --group-by ...`.
- Article claim shape: "on Cloud Run with X, Rails boot is Y% of client-observed cold start; change Z moved p50 by W ms". Every claim needs a lab number from boot-report and a platform number from insitu.

---

## 7. Scope

### v0.2.0 (shippable in a few sessions)

- `hayaoki/insitu` (hooks, middleware, emit, redaction, platform detection)
- `hayaoki cold-start-report`
- `examples/` for Cloud Run and Lambda LWA, plus a README section
- `templates.yml` CI (build + local run + lint)
- Overhead bench (nightly, non-gating)

### Deferred

| Item | Target | Why later |
|---|---|---|
| Puma plugin for the exact listen time | 0.3 | `first_probe` is close enough; Puma 6/7 renamed the hooks (`on_booted` → `after_booted`, to verify) |
| `HAYAOKI_INSITU=trace` (probe in prod, top-N gems) | 0.3 | needs a payload budget and loading through `RUBYOPT` |
| Lambda Telemetry API extension (Rust) | 0.3+ | joins exact Init boundaries; the only justified non-Ruby piece |
| `hayaoki templates` generator | 0.3 | after the templates are validated on real deployments |
| Deploy workflow with secrets | later | needs a cloud account in CI |
| Vernier/rbspy integration, OTel export, warm-latency comparison, per-instance REPORT join | later | not needed for the article |

---

## 8. Implementation order (commit-sized)

| # | Step | Files | Delegate |
|---|---|---|---|
| 1 | Extract `MiniJSON` from the probe; probe uses it; tests unchanged | `lib/hayaoki/mini_json.rb`, `probe.rb` | haiku |
| 2 | Extract the redaction regex into `Hayaoki::Redact` (`group_for(path, specs, root)`) | `lib/hayaoki/redact.rb`, `formatters/redact.rb` | sonnet |
| 3 | `Insitu::Clock` + `/proc` readers + platform detection (pure functions, fixture strings in tests) | `lib/hayaoki/insitu/{clock,proc,platform}.rb` | sonnet |
| 4 | Insitu core: enable gating, hooks (Bundler, `initialize!`, eager_load), marks, `at_exit` fallback, emit | `lib/hayaoki/insitu.rb`, `insitu/hooks.rb`, `insitu/emitter.rb` | **fable** |
| 5 | Middleware: ignore paths, first request, BodyProxy, feature delta, route | `insitu/middleware.rb` | **fable** (review) / sonnet (impl) |
| 6 | Integration test: fixture Rails app in a child process, Rack::MockRequest `/up` then `/`, schema assertions; Rails 7.0–8.x matrix job | `test/insitu/*` , `ci.yml` | sonnet |
| 7 | `cold-start-report` reader + stats + formatters + CLI wiring | `lib/hayaoki/cold_start_report/*`, `cli.rb` | sonnet |
| 8 | `examples/` files + README section (re-check facts, keep the citations) | `examples/**`, `README.md` | sonnet |
| 9 | `templates.yml` CI (build, run, assert, lint) | `.github/workflows/templates.yml` | sonnet |
| 10 | Overhead bench + nightly job | `bench/insitu_overhead.rb` | haiku |
| 11 | CHANGELOG, version 0.2.0, milestone review | | haiku + **fable** review |
| 12 | Cloud measurement scripts; the user runs them | `bench/cloud/*.sh` | sonnet; user runs |

---

## 9. Decisions on the open questions (2026-11-08)

- Q1: Requiring `hayaoki/insitu` enables it in production; `HAYAOKI_INSITU=0` turns it off, `1` forces it on elsewhere.
- Q2: One line per cold start, at the first response (`at_exit` fallback).
- Q3: `examples/` only for 0.2.
- Q4: minimal + Redmine on both platforms; Mastodon local `docker run` only.
- Q5: `controller#action` of the first request is logged.
- Q6: The user measures on both Cloud Run and Lambda with their own accounts.

---

## Sources

- [L1] AWS Lambda execution environment lifecycle (Init 10 s limit, INIT_REPORT, proactive init): https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html
- [L2] AWS Compute Blog, "AWS Lambda standardizes billing for INIT phase" (effective 2025-08-01): https://aws.amazon.com/blogs/compute/aws-lambda-standardizes-billing-for-init-phase/
- [L3] Lambda SnapStart supported runtimes (Java 11+, Python 3.12+, .NET 8+; ruby4.0 not supported): https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html
- [L4] Lambda Managed Instances runtimes: https://docs.aws.amazon.com/lambda/latest/dg/lambda-managed-instances-runtimes.html
- [L5] Lambda Telemetry API: https://docs.aws.amazon.com/lambda/latest/dg/telemetry-api.html
- [L6] AWS Lambda Web Adapter README (1.1.0 image, `AWS_LWA_PORT` default 8080, non-AWS base images): https://github.com/aws/aws-lambda-web-adapter
- [L7] LWA readiness check (`AWS_LWA_READINESS_CHECK_PATH` default `/`, async init 9.8 s): https://aws.github.io/aws-lambda-web-adapter/configuration/readiness-check.html
- [C1] Cloud Run container runtime contract (env vars, 4 min listen, request queueing): https://docs.cloud.google.com/run/docs/container-contract
- [C2] Cloud Run health checks (startup probe fields and defaults): https://docs.cloud.google.com/run/docs/configuring/healthchecks
- [C3] Cloud Run CPU limits / startup CPU boost: https://docs.cloud.google.com/run/docs/configuring/cpu
- To verify: `run.googleapis.com/container/startup_latencies` (seen only in third-party integration docs, e.g. https://docs.datadoghq.com/integrations/google-cloud-run); the Lambda reserved env var names `AWS_LAMBDA_INITIALIZATION_TYPE` and `AWS_LAMBDA_LOG_STREAM_NAME` (https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html).
