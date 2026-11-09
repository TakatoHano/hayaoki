# Changelog

## [0.3.0] - 2026-11-09

### Added

- `cold-start-report` prints hints: likely causes outside app code, with the numbers behind them. Five rules: `bootsnap_off`, `bootsnap_cache_cold`, `gc_pressure`, `lambda_init_near_limit`, `prestarted_process`. Each needs at least 3 ok cold starts with a plausible start.
- `--no-hints` leaves the hints out.
- JSON output gains `hints`, `hints_n`, `hints_mixed` and `platform_init_reports`. The additions are optional; the report version stays 1.
- The reader counts Lambda `INIT_REPORT` status lines (for example `timeout`), used by `lambda_init_near_limit`.

### Fixed

- Platform lines in JSONL input were counted twice.


## [0.2.1] - 2026-11-09

### Added

- `cold-start-report`: adds "ready (from load)" and "first response (from load)" rows (`ready_from_load_ms`, `first_response_from_load_ms`), timed from hayaoki's load, so lines with a rejected process start still give numbers.

### Fixed

- In-situ: a process start read from `/proc/self/stat` more than 600 s before hayaoki loaded (or after it) is no longer used. Seen once in seven Cloud Run gen1 cold starts as a `pre_load` of about 2 hours. The line then falls back to the load origin (`start_source: "load"`, `start_at` null) and adds `start_rejected: {"reason", "pre_load_ms"}`. The schema version stays 1.
- `cold-start-report`: lines already written by 0.2.0 with such a start keep their other phases, but their `pre_load`, `to_ready` and `to_first_response` are left out of the distributions, with a warning that gives the count (`implausible_start` in JSON output).

## [0.2.0] - 2026-11-08

### In-situ cold-start logging

- `require "hayaoki/insitu"` in `config/boot.rb` (after `bundler/setup`) records each production cold start and writes one JSON line after the first non-health-check response: time from process start to ready and to the first response, phases (Bundler.require, initialize, eager load and its top namespaces), platform (Cloud Run, Lambda, generic), and the first request (route `controller#action`, status, files loaded during the request, GC).
- On by default in production once required; `HAYAOKI_INSITU=0` turns it off, `1` turns it on elsewhere. Adds about 1 ms to boot and a few tens of nanoseconds to later requests.
- Writes `no_request`, `incomplete` or `boot_error` lines when a server exits without a complete first response or fails to boot. Rake tasks (including `bin/rails db:prepare`), `rails console`/`runner`, job processes and forking parents (Puma cluster master) do not write `no_request` lines. Each forked worker writes its own line, timed from the master's start.
- Works without Rails via `use Hayaoki::Insitu::Middleware`.

### cold-start-report

- `hayaoki cold-start-report` reads these lines from JSONL, Cloud Logging exports, CloudWatch Logs (including Logs Insights CSV and Lambda `REPORT` lines for `Init Duration`) and prints p50/p90/p99/max per phase, top first-request routes, and files loaded lazily by gem. Supports `--group-by`, `--since`, `--until`, `--exclude-proactive`, and `--format json`.

### Examples

- `examples/cloud_run` and `examples/lambda_lwa`: Dockerfiles with bootsnap precompiled at build time, a Cloud Run service with startup CPU boost and a `/up` startup probe, and a Lambda Web Adapter setup. CI builds and runs both images.

## [0.1.0] - 2026-11-08

First release.

### Measurement

- `hayaoki boot-report` boots a Rails application several times in a child process and reports the median and range of each measurement, in text, JSON, or speedscope format.
- A probe injected with `ruby -r` records `require`, `require_relative`, `load`, initializers, `on_load` hooks, eager loading (Zeitwerk and each `config.eager_load_namespaces` entry, such as `TZInfo.eager_load!`), `Bundler.require`, and `initialize!`. It has no runtime dependencies, coexists with bootsnap and Zeitwerk, and adds about 2% to boot time.
- Boot time is broken down by phase (vm boot, bundler require, initialize, eager load), by gem, by initializer, by `on_load` hook, and by eager load namespace. A category table (`gem`, `app`, `stdlib`, `other`, `init_body`, `unattributed`) adds up to the total boot time.
- Each `require` is attributed to the gem or app file it loaded. Requires that cannot be matched to a loaded file are reported as a warning. Spans on background threads are listed but left out of the totals.
- Applications that are themselves gems (`gemspec`, engine dummy apps) are handled: their own files count as `app`.
- Runs with bootsnap's cache warm, cold, or both, and measures the probe's own overhead.
- Supports Ruby 3.2 or later and Rails 7.0 or later. Before measuring, hayaoki checks that the application's `ruby` is new enough and points to `--ruby` if not.

### Suggestions

Each suggestion shows its evidence and an upper bound of the time it could save, and marks findings whose savings overlap. They were checked against Mastodon and Redmine.

- `bootsnap_ineffective`: bootsnap missing, or its cache not used.
- `dev_gems_in_production`: development or test gems loaded in production, based on the Gemfile's groups (including `eval_gemfile`).
- `heavy_app_initializer`: slow files in `config/initializers`.
- `tzinfo_eager_load`: `TZInfo.eager_load!` reading every time zone at boot (200–330 ms in Linux containers, Rails 7.2+).
- `devise_reload_routes`: Devise loading the routes a second time before eager loading.
- `controller_action_methods`: `action_methods` computed for every controller at boot.
- `unused_heavy_gem`: heavy gems with no references in the app's code.
- `eager_load_tradeoff`: eager loading taking a large share of boot.

### Output and options

- Options for the number of runs, environment, bootsnap mode, Ruby executable, entry file, timeout, output file, rows per ranking, and suggestion thresholds.
- `--redact` replaces the app directory, gem paths, and home directory in the output, so a report can be shared.
- JSON output leaves out the stderr of failed runs, because it may contain secrets.
