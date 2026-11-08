# Changelog

## [0.1.0] - 2026-11-08

- `hayaoki boot-report` measures boot time over several runs and reports the median and range, in text, JSON, or speedscope format.
- The probe, injected with `ruby -r`, records require, require_relative, load, initializer, on_load, eager_load, `Bundler.require`, and `initialize!` as spans.
- `config.eager_load_namespaces` entries (e.g. `TZInfo.eager_load!`) are recorded as eager_load spans and attributed to the gem that defines them, instead of disappearing into the `eager_load!` initializer body.
- Requires are matched to loaded files for `./x`, `../x`, `x.so` (loaded as `.bundle` on macOS) and built-in extensions such as `prism/prism.so`. Before, these fell back to the last loaded file, which could be another thread's. Remaining fallbacks are counted and reported as a warning.
- Before measuring, the child `ruby` is checked to be Ruby 3.2 or later, with a one-line error that points to `--ruby` otherwise.
- Phase breakdown (vm boot, bundler require, initialize) and per-gem and per-initializer rankings.
- Improvement suggestions, printed as candidates: bootsnap effectiveness, heavy app initializers, unused heavy gems, dev gems in production, and eager load trade-offs. Disable with `--no-suggestions`.
- `tzinfo_eager_load` suggestion: `TZInfo.eager_load!` takes 200–330 ms in Linux containers (see `bench/tzinfo_eager_load.rb`), and it can be made lazy with one line.
- `devise_reload_routes` and `controller_action_methods` suggestions, measured on Mastodon and Redmine with `bench/boot_variants.rb`.
- A ranking of `config.eager_load_namespaces` entries in the text output, and `eager_namespaces` in the JSON output.
- Options for runs, environment, bootsnap mode (`warm`, `cold`, `both`), entry file, timeout, output file, and rows per ranking, plus thresholds for suggestions.
- The probe has no runtime dependencies and writes JSON with its own encoder.
- `--redact` replaces absolute paths in the output (text, JSON, and speedscope): the app directory with `<app>`, gem paths (including bundler git gems) with `<gem:name>/`, and the home directory with `~`.
- A category table in the text and JSON output, with an `unattributed` row (boot time minus attributed self time) so the totals add up.
- Applications that are themselves gems (`gemspec`, engine dummy apps, `path: "."`) are categorized as `app` for files under `app`, `config`, `lib`, and `db`.
- JSON output omits the stderr of failed runs, which may contain secrets. It keeps the message, exit status, and error class.
