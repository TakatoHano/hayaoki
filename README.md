# hayaoki

Wake your Rails app up early: find out where its boot time goes, and what to change.

*hayaoki* (早起き) means "getting up early" in Japanese. It is a diagnostic tool: it measures and explains boot time, and does not make boot faster just by being installed.

hayaoki measures where a Rails application's boot time goes and reports it by phase, by gem, and by initializer. The current release provides `hayaoki boot-report`.

## Installation

```sh
gem install hayaoki
```

hayaoki is a standalone command. You do not need to add it to your Gemfile.

## Usage

```sh
hayaoki boot-report [APP_DIR]
```

`APP_DIR` defaults to the current directory.

| Option | Description |
| --- | --- |
| `--runs N` | number of measured runs (default 5) |
| `--env ENV` | `RAILS_ENV` (default `production`) |
| `--bootsnap MODE` | `warm`, `cold`, or `both` (default `warm`) |
| `--ruby PATH` | ruby executable (default `ruby`) |
| `--entry PATH` | boot entry file (default `config/environment`) |
| `--timeout SEC` | per-run timeout in seconds (default 120) |
| `--format FORMAT` | `text`, `json`, or `speedscope` (default `text`) |
| `--output FILE` | write to FILE instead of stdout |
| `--top N` | rows per ranking (default 10) |
| `--no-suggestions` | do not print improvement suggestions |
| `--initializer-threshold MS` | app initializer threshold for suggestions (default 50) |
| `--gem-threshold MS` | gem self time threshold for suggestions (default 30) |
| `--redact` | replace absolute paths in the output (all formats): the app directory (and its realpath) with `<app>`, gem paths with `<gem:name>/`, the home directory with `~` |
| `--version` | show version |
| `-h`, `--help` | show help |

Example output:

```
total[warm]: 687.8 ms [684.3-699.4]
Phases (median)
  vm boot                █                            28.2 ms
  bundler require        ████████                     195.6 ms
  initialize             ███████████                  267.0 ms
```

### cold-start-report

```sh
hayaoki cold-start-report [FILE...]
```

Summarizes the `cold_start` log lines written by the in-situ recorder. It reads FILEs, or stdin when none are given. Bare JSON lines, Cloud Logging exports (`jsonPayload`) and CloudWatch lines (prefix before the JSON, or a `message` string) are accepted; other lines are skipped and counted. `Init Duration` in Lambda `REPORT` lines is reported as `platform_init_ms`.

The output has the line count, p50/p90/p99/max for ready, first response and each phase, the mean `eager_top`, the first-request routes and lazy-loaded feature groups, and the split between user-facing and proactive starts.

The "(from load)" rows count time from hayaoki's load instead of process start, so they still have numbers when the process start is rejected. On Cloud Run gen2 the process start is not the cold-start origin: instances appear to be created ahead and frozen until a request, so `pre_load` and the ready times come out as tens of minutes and are dropped. Use the "(from load)" rows together with Cloud Run's `container/startup_latencies` metric or client-side timing for the full picture.

| Option | Description |
| --- | --- |
| `--group-by KEY` | group by a dotted path or alias: `revision`, `platform.kind`, `runtime.ruby`, `init_type` |
| `--since TIME`, `--until TIME` | filter by `start_at` (ISO 8601) |
| `--format FORMAT` | `text` or `json` (default `text`) |
| `--exclude-proactive` | drop lines with `idle` > 1000 ms (Lambda proactive init) |
| `--no-hints` | leave out the hints |

#### Hints

Below the numbers, the report can print hints: likely causes outside app code, each with the numbers behind it. A hint is a lead to check, not a verdict.

Hints need at least 3 ok cold starts with a plausible start. With fewer, the report says so and prints none. Levels:

- `likely`: the data points to one cause.
- `possible`: worth checking; the data fits but does not prove it.
- `note`: context for reading the numbers.

| Rule | Fires when | Level |
| --- | --- | --- |
| `bootsnap_off` | bootsnap was not loaded in at least half of the cold starts | likely |
| `bootsnap_cache_cold` | bootsnap is on, but its cache dir did not exist at boot in at least half | likely |
| `gc_pressure` | median GC time is 20% or more of boot CPU time | possible |
| `lambda_init_near_limit` | Lambda only: any Init timeout, or p90 of Init or `to_ready` is 7 s or more (limit 10 s) | likely |
| `cpu_bound_boot` | median CPU share of boot is 70% or more (of one core, or of the quota if below 1 vCPU) | likely if quota < 1 vCPU (not Lambda), else possible |
| `wait_dominated_boot` | median CPU share of boot is 50% or less | likely |
| `memory_near_limit` | median RSS is 80% or more of the memory limit, or any line is 90% or more | likely |
| `prestarted_process` | at least half of the lines have a rejected or implausible process start | note |

CPU share is CPU time divided by wall time from load. It needs lines from hayaoki 0.3.1 or later, and `cpu_bound_boot` and `wait_dominated_boot` also need a median ready time of 3 s or more. Preloaded forked worker lines are skipped by the CPU rules.

`wait_dominated_boot` says what the time off CPU was, from the median share of it that the main thread spent in the run queue (`wait_kind` in the evidence), over the lines that waited:

- `cpu`: 50% or more. The wait was for a CPU; a quota or other work on the same CPUs held boot back. The text suggests more CPU (cpu=1 or more) or startup CPU boost only when the CPU quota is unknown or below 1; with a quota of 1 or more it says a higher CPU limit or startup CPU boost may help.
- `not_cpu`: 20% or less. Not a CPU wait, so throttling by a quota is unlikely. On Lambda and Cloud Run, if IO stall (PSI) covers half of the time off CPU or more, the text names file IO as the likely main cause; the same for steal, compared per CPU (steal is summed over all CPUs, so it is divided by the CPU count in `limits.nproc`, and no steal sentence is written when that count is missing). PSI and steal are system-wide, so on other platforms the numbers are shown without a cause sentence.
- `mixed`: in between.
- `unknown`: fewer than 3 of those lines have the run-queue fields (0.3.1 lines, gVisor, forked workers). The text is the one from 0.4.2, plus the counter sentence when the lines have counters.

The evidence also has `wait_lines` (the lines that waited and have `cpu_at_load_ms`, so the wait is measured from load; `waited_lines` counts every CPU-rule line at 50% or less CPU share, also those without `cpu_at_load_ms`), `non_cpu_ms_p50`, `runq_share_of_non_cpu_p50`, the medians of the counter deltas from load to emit (`majflt_p50`, `io_read_bytes_p50`, `steal_ms_p50`, `psi_io_some_ms_p50`, `psi_cpu_some_ms_p50`) and `unaccounted_ms_p50`: time off CPU that run queue, IO stall and steal do not explain (network wait, a paused instance, file IO that PSI does not count). Counters that are null in the lines are null here. Details are in [docs/design/resource-hints.md](docs/design/resource-hints.md).

On Lambda the CPU quota is unknown, and Init CPU reportedly does not follow the memory setting, so these hints do not suggest more memory. See [this article](https://dev.classmethod.jp/articles/lambda-boost-host-cpu-in-init-phase/) and the [Lambda Web Adapter async init docs](https://aws.github.io/aws-lambda-web-adapter/configuration/async-init.html).

Example:

```
Hints (likely causes outside app code; based on 12 ok cold starts, 12 with a plausible start)
  likely    bootsnap_off            bootsnap was not loaded in 12 of 12 cold starts. ...
  possible  gc_pressure             GC took 24% of boot CPU (median 410 ms of 1700 ms, 18 GCs). ...
```

Use `--no-hints` to leave them out. In JSON they are under `hints`, `hints_n` and `hints_mixed`.

If lines come from different configurations (for example two revisions or Ruby versions), the hints are flagged, because the mix can hide or invent a cause. Use `--group-by` to split them.

Lambda `Init Duration` and `INIT_REPORT` lines have no id, so pass each Lambda log export once. If exports overlap, the Init lines are counted twice.

## In-situ cold-start logging

`boot-report` measures boot in a lab. The in-situ recorder measures real cold starts of a deployed app: it writes one JSON line per process, which `hayaoki cold-start-report` then summarizes. Installing it does not speed anything up.

Install:

```ruby
# Gemfile
gem "hayaoki", require: false

# config/boot.rb
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "hayaoki/insitu"   # before bootsnap/setup, so its cost is counted
require "bootsnap/setup"
```

Do not require it before `bundler/setup`: RubyGems could activate a hayaoki version that conflicts with the lockfile. `gem "hayaoki", require: "hayaoki/insitu"` also works, but then the start of `Bundler.require` is not recorded.

The line is written to stdout after the first non-health-check response. If no request came, a `no_request` line is written at exit; if the first request started but its response never finished (for example the process was stopped mid-request), an `incomplete` line is written instead. It is a bare JSON object, so Cloud Logging stores it in `jsonPayload` and CloudWatch Logs Insights can query its fields. It contains:

- marks and phases in ms since process start (`phases_ms.to_ready`, `initialize`, `eager_load`, `first_request`, and so on), with the process start read from `/proc/self/stat` on Linux
- `platform` (Cloud Run, Lambda, or generic), Ruby, Rails and hayaoki versions, and whether bootsnap and its cache were present
- the top eager-loaded namespaces, and the first request's route, status and newly loaded files counted by gem
- process facts: RSS, CPU time, GC counts, loaded feature count, and on Linux the main thread's run-queue wait (`/proc/self/schedstat`) at load and at emit
- counters that show what non-CPU time was, in `proc`, each read at load (`*_at_load`) and at emit: `majflt` (major page faults of the process), `io_read_bytes` and `io_rchar` (bytes of the process: read from a block device, and passed to read calls; `io_read_bytes` stays 0 on overlay, FUSE and virtiofs), `steal_ms` (hypervisor steal, system-wide, summed over CPUs), `psi_io_some_ms` and `psi_cpu_some_ms` (time with at least one task stalled on IO or CPU, system-wide, from `/proc/pressure`). The at-load keys are `majflt_at_load`, `io_read_bytes_at_load`, `io_rchar_at_load`, `steal_at_load_ms`, `psi_io_some_at_load_ms`, `psi_cpu_some_at_load_ms`. Each value is null where its file is missing (no `/proc/self/io`, no PSI, not Linux)

Query strings, raw paths, headers, environment values, exception messages and file names are never logged. The full schema is in [docs/design/phase2.md](docs/design/phase2.md#31-line-schema-v1).

| Variable | Default | Meaning |
| --- | --- | --- |
| `HAYAOKI_INSITU` | on when `RAILS_ENV` or `RACK_ENV` is `production` | `0` turns it off (the require does nothing), `1` forces it on |
| `HAYAOKI_INSITU_OUT` | `stdout` | `stdout`, `stderr`, or a file path (append) |
| `HAYAOKI_INSITU_IGNORE_PATHS` | `/up` and `$AWS_LWA_READINESS_CHECK_PATH` | comma-separated health-check paths; a request to one sets `first_probe` and does not count as the first request |
| `HAYAOKI_INSITU_EMIT` | `first_request` | `ready` emits at the end of `initialize!` instead, for apps whose first request may not come |
| `HAYAOKI_INSITU_EMIT_AT` | `app_return` on Lambda, else `body_close` | where the first request ends and the line is written: when the server closes the response body, or when the app returns the response |

Known limitations:

- If `config/boot.rb` loads it but the app never calls `Bundler.require`, the Rails hooks are not installed: there are no initialize or eager-load marks and no middleware, only the line at exit.
- Eager-load timing covers the namespaces in `config.eager_load_namespaces` at the start of `initialize!`. A namespace added later by an initializer is not timed.
- `proc.i18n_loaded` is informative only when `config.eager_load` is false. With eager load on it is always true.
- The `no_request` line is not written by rake tasks (including `bin/rails db:prepare` and other tasks run through `bin/rails`), `rails console`, `rails runner`, or a process that forked children (for example the Puma cluster master; its workers write their own lines). With `HAYAOKI_INSITU_EMIT=ready` the same processes write no line.
- Job processes started as `sidekiq`, `bin/jobs` (Solid Queue) or `good_job` are skipped by program name. Other non-web processes that boot the app from the same image (custom job runners, a Solid Queue supervisor forked from Puma by `plugin :solid_queue`) write a `no_request` line at exit; set `HAYAOKI_INSITU=0` for them.
- Servers that boot the app once and then fork workers (Puma cluster with `preload_app!`, Unicorn with `preload_app true`, Pitchfork, Passenger smart spawning): phases in a worker's line are measured from the master's start, and `marks_ms.forked` is when the worker was forked. A worker restarted long after boot therefore shows a large `to_first_response`; check `forked`. The worker's CPU clock starts again at fork, so in these lines `proc.cpu_ms` covers only the worker, `proc.cpu_at_load_ms`, `proc.main_thread_runq_wait_at_load_ms`, the other `proc.*_at_load` counters above and `phases_cpu_ms.load_to_*` are null, and `phases_cpu_ms.bundler_require` / `initialize` are the master's. Without preload, each worker boots the app itself and its line is like a single-process one.
- On Lambda the line is written when the app returns the response, before the body is sent, because Lambda freezes the environment right after the response. `first_response_end`, `first_request` and `to_first_response` therefore leave out body iteration and the send there. This is small for a normal Rails response and can be large for a streaming one. `first_request.end_at` says which point was used (`app_return` or `body_close`). Elsewhere the line is written at body close; `HAYAOKI_INSITU_EMIT_AT` changes this.
- Lambda Web Adapter's readiness check path defaults to `/`. If `AWS_LWA_READINESS_CHECK_PATH` is not set, the adapter's check to `/` counts as the first request. Set `AWS_LWA_READINESS_CHECK_PATH=/up` (the recorder then ignores it), or add the path to `HAYAOKI_INSITU_IGNORE_PATHS`. `/` is not ignored automatically, because it may also be a real first request.
- The process start comes from `/proc/self/stat` and `CLOCK_BOOTTIME`. This has not been checked on Cloud Run's first-generation execution environment (gVisor). If `start_at` or `pre_load` look wrong there, use the second-generation environment (`run.googleapis.com/execution-environment: gen2`).
- Time before the process starts (image pull, sandbox creation) is not visible to it. Use the platform's numbers (Lambda `Init Duration`, Cloud Run startup latency) for that.

Rack apps without Rails: the Rails hooks do nothing there, so add the middleware yourself. Load `hayaoki/insitu` as early as possible (after `bundler/setup`), then in `config.ru`:

```ruby
require "hayaoki/insitu"
require "hayaoki/insitu/middleware"
use Hayaoki::Insitu::Middleware   # passes requests through untouched when the recorder is off
```

There are no initialize or eager-load marks in this case; `to_ready` comes from the first health-check request, if any.

Deployment templates for Cloud Run and Lambda (Lambda Web Adapter) are in [`examples/`](examples/).

## Suggestions

| Rule | Confidence | What it looks for |
| --- | --- | --- |
| `dev_gems_in_production` | high / medium / low | development or test gems loaded in production (high: direct and not in a group; low: transitive) |
| `bootsnap_ineffective` | high | bootsnap missing, or its cache not helping |
| `heavy_app_initializer` | medium | app initializers slower than `--initializer-threshold` |
| `tzinfo_eager_load` | medium | `TZInfo.eager_load!` loading every time zone at boot (see below) |
| `devise_reload_routes` | medium (Devise 5+) / low | Devise reloading the routes before eager loading; they are loaded again later in boot |
| `controller_action_methods` | low | `AbstractController.eager_load!` computing `action_methods` for every controller at boot |
| `unused_heavy_gem` | low | heavy gems with no references in app code (candidates for `require: false`) |
| `eager_load_tradeoff` | info | eager loading taking a large share of boot |

Estimated savings are upper bounds. Findings can overlap, and the output marks which ones do, so do not add them up.

### TZInfo eager loading

In production, Rails 7.2 and later add `TZInfo` to `config.eager_load_namespaces`, and `TZInfo.eager_load!` reads all ~600 time zones at boot. Measured with [`bench/tzinfo_eager_load.rb`](https://github.com/TakatoHano/hayaoki/blob/main/bench/tzinfo_eager_load.rb) (median of 7 fresh processes on a GitHub-hosted runner, Ruby 3.4):

| Environment | `TZInfo.eager_load!` |
| --- | --- |
| `ruby:3.4-slim`, system zoneinfo / with `tzinfo-data` | 243 ms / 194 ms |
| `ruby:3.4-alpine` + `tzdata` / with `tzinfo-data` | 330 ms / 228 ms |
| AWS Lambda `ruby:3.4`, system zoneinfo / with `tzinfo-data` | 319 ms / 202 ms |
| macOS (Apple silicon, local) | 112 ms |

Removing it (`Rails.application.config.eager_load_namespaces.delete(TZInfo)` in an initializer) leaves 5–15 ms at boot. Each zone is then loaded on first use, in under 1 ms. The trade-off is that forking servers no longer share the zone data copy-on-write.

### Measured on real applications

[`bench/boot_variants.rb`](https://github.com/TakatoHano/hayaoki/blob/main/bench/boot_variants.rb) boots an application with one setting changed at a time (median of fresh processes, GitHub-hosted runner, official Docker images, `RAILS_ENV=production`). The `real-apps` workflow runs it. Boot times vary by several hundred ms between runners, so compare within one run.

| Change | Mastodon 4.7.5 | Redmine 7.0 | Cost moved to later |
| --- | --- | --- | --- |
| `eager_load_namespaces.delete(TZInfo)` | −128 ms | −193 to −328 ms | under 1 ms per zone used |
| Devise `config.reload_routes = false` | −194 ms | (no Devise) | none: the routes are loaded once, later in boot |
| `eager_load_namespaces.delete(AbstractController)` | −201 ms | −31 ms | 217 ms in total across 336 controllers, about 0.65 ms on each controller's first request |
| `eager_load_namespaces.delete(I18n)` | −108 ms | −286 ms | 182 ms / 317 ms on the first translation |
| `config.i18n.available_locales = [:en]` | no gain | no gain | every locale file is still parsed |

hayaoki has no I18n suggestion: making it lazy only moves the whole cost to the first translation, which nearly every request needs.

## How it works

hayaoki runs your application in a child process with a probe injected through `ruby -r`. The probe hooks the require family of methods with an alias chain, not `prepend`, so it coexists with bootsnap, Zeitwerk, and bundled_gems. Rails-specific hooks (initializers, on_load hooks, eager loading, `Bundler.require`, and `initialize!`) are installed lazily, when the corresponding file is loaded. The measured overhead is about 2%.

The design is described in [docs/design/probe.md](https://github.com/TakatoHano/hayaoki/blob/main/docs/design/probe.md).

## Notes

- The application is booted with the `ruby` found on `PATH` in the application directory (so rbenv, asdf, or mise pick the app's version), or with `--ruby PATH`. It must be Ruby 3.2 or later; hayaoki checks this before measuring.
- By default hayaoki boots the application with `RAILS_ENV=production`. Boot may then need access to external services or credentials. If so, use `SECRET_KEY_BASE_DUMMY=1` for a dummy secret key, and `--env` to choose another environment.
- Suggestions are candidates. Verify each one before applying it.
- Output contains absolute paths unless you pass `--redact`. `--redact` rewrites paths only. It does not remove other content, so review the output before sharing it.
- JSON output does not include the stderr of failed runs, because it may contain secrets. It keeps the error message, exit status, and error class. When every run fails, hayaoki prints the stderr tail to the terminal.
- The category table (`gem`, `app`, `stdlib`, `other`, `init_body`, `unattributed`) sums to boot time. `init_body` is the own time of initializer blocks (not blamed on the gem that defines them). `unattributed` is boot time minus the self time attributed to files, initializer bodies, and on_load hooks. It covers time in `run_load_hooks` itself, the self time of phase and Zeitwerk eager load spans, and time outside any span. Background-thread spans are excluded.

## Requirements

- Ruby 3.2 or later
- Rails 7.0 or later
- macOS or Linux

## License

MIT. See [LICENSE](LICENSE).
