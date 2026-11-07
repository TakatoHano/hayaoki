# hayate

Rails cold-start toolkit

hayate measures where a Rails application's boot time goes and reports it by phase, by gem, and by initializer. The current release provides `hayate boot-report`.

## Installation

```sh
gem install hayate
```

hayate is a standalone command. You do not need to add it to your Gemfile.

## Usage

```sh
hayate boot-report [APP_DIR]
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

## How it works

hayate runs your application in a child process with a probe injected through `ruby -r`. The probe hooks the require family of methods with an alias chain, not `prepend`, so it coexists with bootsnap, Zeitwerk, and bundled_gems. Rails-specific hooks (initializers, on_load hooks, eager loading, `Bundler.require`, and `initialize!`) are installed lazily, when the corresponding file is loaded. The measured overhead is about 2%.

The design is described in [docs/design/probe.md](docs/design/probe.md).

## Notes

- By default hayate boots the application with `RAILS_ENV=production`. Boot may then need access to external services or credentials. If so, use `SECRET_KEY_BASE_DUMMY=1` for a dummy secret key, and `--env` to choose another environment.
- Suggestions are candidates. Verify each one before applying it.
- JSON and speedscope output contain absolute paths. A `--redact` option is planned but is not yet available.

## Requirements

- Ruby 3.2 or later
- Rails 7.0 or later
- macOS or Linux

## License

MIT. See [LICENSE](LICENSE).
