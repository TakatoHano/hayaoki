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

| Option | Description |
| --- | --- |
| `--group-by KEY` | group by a dotted path or alias: `revision`, `platform.kind`, `runtime.ruby`, `init_type` |
| `--since TIME`, `--until TIME` | filter by `start_at` (ISO 8601) |
| `--format FORMAT` | `text` or `json` (default `text`) |
| `--exclude-proactive` | drop lines with `idle` > 1000 ms (Lambda proactive init) |

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
