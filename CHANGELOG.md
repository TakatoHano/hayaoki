# Changelog

## [Unreleased]

- `hayate boot-report` measures boot time over several runs and reports the median and range, in text, JSON, or speedscope format.
- The probe, injected with `ruby -r`, records require, require_relative, load, initializer, on_load, eager_load, `Bundler.require`, and `initialize!` as spans.
- Phase breakdown (vm boot, bundler require, initialize) and per-gem and per-initializer rankings.
- Improvement suggestions, printed as candidates: bootsnap effectiveness, heavy app initializers, unused heavy gems, dev gems in production, and eager load trade-offs. Disable with `--no-suggestions`.
- Options for runs, environment, bootsnap mode (`warm`, `cold`, `both`), entry file, timeout, output file, and rows per ranking, plus thresholds for suggestions.
- The probe has no runtime dependencies and writes JSON with its own encoder.
