# Changelog

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
