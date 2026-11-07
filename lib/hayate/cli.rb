# frozen_string_literal: true

require "optparse"
require_relative "../hayate"
require_relative "version"

module Hayate
  class CLI
    FORMATS = %w[text json speedscope].freeze
    USAGE = "Usage: hayate boot-report [options] [APP_DIR]"

    def self.start(argv = ARGV, stdout: $stdout, stderr: $stderr)
      new(stdout: stdout, stderr: stderr).run(argv)
    end

    def initialize(stdout: $stdout, stderr: $stderr)
      @out = stdout
      @err = stderr
    end

    # 終了コードを返す。
    def run(argv)
      argv = argv.dup
      cmd = argv.shift
      case cmd
      when "boot-report" then boot_report(argv)
      when "--version", "-v", "version" then @out.puts("hayate #{Hayate::VERSION}"); 0
      when nil, "-h", "--help", "help" then @out.puts(top_help); cmd.nil? ? 1 : 0
      else
        @err.puts "hayate: unknown command '#{cmd}'\n#{top_help}"
        1
      end
    end

    def default_options
      { runs: 5, env: "production", bootsnap: :warm, ruby: "ruby", entry: "config/environment", timeout: 120,
        format: "text", output: nil, top: 10 }
    end

    # オプション解析だけ行う。[options, app_dir] を返す (--help / --version は :exit を返す)
    def parse(argv)
      opts = default_options
      parser = OptionParser.new do |o|
        o.banner = USAGE
        o.on("--runs N", Integer, "number of measured runs (default 5)") { |v| opts[:runs] = v }
        o.on("--env ENV", "RAILS_ENV (default production)") { |v| opts[:env] = v }
        o.on("--bootsnap MODE", %w[warm cold both], "warm|cold|both (default warm)") { |v| opts[:bootsnap] = v.to_sym }
        o.on("--ruby PATH", "ruby executable (default ruby)") { |v| opts[:ruby] = v }
        o.on("--entry PATH", "boot entry file (default config/environment)") { |v| opts[:entry] = v }
        o.on("--timeout SEC", Float, "per-run timeout in seconds (default 120)") { |v| opts[:timeout] = v }
        o.on("--format FORMAT", FORMATS, "text|json|speedscope (default text)") { |v| opts[:format] = v }
        o.on("--output FILE", "write to FILE (default stdout)") { |v| opts[:output] = v }
        o.on("--top N", Integer, "rows per ranking (default 10)") { |v| opts[:top] = v }
        o.on("--no-suggestions", "do not print improvement suggestions") { opts[:suggestions] = false }
        o.on("--initializer-threshold MS", Float, "app initializer threshold for suggestions (default 50)") { |v| opts[:initializer_threshold] = v }
        o.on("--gem-threshold MS", Float, "gem self time threshold for suggestions (default 30)") { |v| opts[:gem_threshold] = v }
        o.on("--redact", "replace home dir with ~, app root with <app>, gem paths with <gem:name> (json/speedscope)") { opts[:redact] = true }
        o.on("--version", "show version") { opts[:action] = :version }
        o.on("-h", "--help", "show this help") { opts[:action] = :help }
      end
      rest = parser.parse(argv)
      raise OptionParser::InvalidArgument, "--runs must be >= 1" if opts[:runs] < 1
      raise OptionParser::InvalidArgument, "--top must be >= 1" if opts[:top] < 1
      raise OptionParser::NeedlessArgument, rest[1..].join(" ") if rest.size > 1
      @parser = parser
      [opts, rest.first || Dir.pwd]
    end

    private

    def top_help = "#{USAGE}\n       hayate --version\n\nRun `hayate boot-report --help` for options."

    def boot_report(argv)
      opts, app_dir = begin
        parse(argv)
      rescue OptionParser::ParseError => e
        @err.puts "hayate: #{e.message}\n#{USAGE}"
        return 1
      end
      case opts[:action]
      when :help then @out.puts(@parser.help); return 0
      when :version then @out.puts("hayate #{Hayate::VERSION}"); return 0
      end
      unless File.directory?(app_dir)
        @err.puts "hayate: APP_DIR not found: #{app_dir}"
        return 1
      end

      require_relative "boot_report/runner"
      require_relative "boot_report/aggregator"
      runner = BootReport::Runner.new(app_dir: app_dir, runs: opts[:runs], env: opts[:env], bootsnap: opts[:bootsnap],
                                      ruby: opts[:ruby], entry: opts[:entry], timeout: opts[:timeout], on_progress: progress_printer)
      result = runner.run
      text = render(result, opts, app_dir)
      if opts[:output]
        begin
          File.write(opts[:output], text)
        rescue SystemCallError => e
          @err.puts "hayate: cannot write #{opts[:output]}: #{e.message}"
          return 1
        end
        @err.puts "wrote #{opts[:output]}"
      else
        @out.write(text)
      end
      0
    rescue BootReport::RunError => e
      report_error(e, opts)
      1
    rescue Errno::ENOENT => e
      @err.puts "hayate: could not start the child process (--ruby #{opts[:ruby].inspect}, APP_DIR #{app_dir.inspect}): #{e.message}"
      @err.puts "Check that the --ruby executable exists and is on PATH."
      1
    rescue SystemCallError => e
      @err.puts "hayate: #{e.message}"
      1
    end

    def render(result, opts, app_dir = Dir.pwd)
      case opts[:format]
      when "speedscope"
        require_relative "boot_report/formatters/speedscope"
        BootReport::Formatters::Speedscope.new.format(result)
      else
        reports = BootReport::Aggregator.new.aggregate_result(result)
        if opts[:format] == "json"
          require_relative "boot_report/formatters/json"
          BootReport::Formatters::Json.new.with_suggestions(*suggest(result, reports, opts, app_dir)).format(reports)
        else
          require_relative "boot_report/formatters/text"
          BootReport::Formatters::Text.new(top: opts[:top]).with_suggestions(*suggest(result, reports, opts, app_dir)).format(reports)
        end
      end
    end

    # [Suggestion の配列, 警告の配列]。--no-suggestions なら [nil, []] (formatter は節を出さない)。
    def suggest(result, reports, opts, app_dir)
      return [nil, []] if opts[:suggestions] == false
      require_relative "boot_report/advisor"
      kw = {}
      kw[:initializer_threshold_ms] = opts[:initializer_threshold] if opts[:initializer_threshold]
      kw[:gem_threshold_ms] = opts[:gem_threshold] if opts[:gem_threshold]
      advisor = BootReport::Advisor.new(reports.values.first, app_dir: File.expand_path(app_dir), result: result, **kw)
      [advisor.suggestions, advisor.warnings]
    end

    # Runner の on_progress から stderr に 1 行ずつ出す。
    def progress_printer
      lambda do |ev|
        case ev["phase"]
        when :warmup then @err.puts "warmup (#{ev["bootsnap"]})..."
        when :probe then @err.puts "run #{ev["index"]}/#{ev["total"]} (#{ev["bootsnap"]})..."
        end
      end
    end

    SECRET_HINT = /credentials|secret_key_base|master[ _.]?key|RAILS_MASTER_KEY/i

    def report_error(e, opts = {})
      case e.reason
      when :app_dir, :no_lockfile, :interrupted
        @err.puts "hayate: #{e.message.lines.first.to_s.strip}"
        return
      end
      @err.puts "hayate: boot failed (#{e.reason})"
      @err.puts e.message.lines.first.to_s.strip
      if e.probe_error
        @err.puts "error: #{e.probe_error["class"]}: #{e.probe_error["message"]}"
      end
      if e.open_span
        @err.puts "last open span: kind=#{e.open_span["kind"]} #{e.open_span["name"]}"
      end
      unless e.stderr_tail.strip.empty?
        @err.puts "--- stderr (tail) ---"
        @err.puts e.stderr_tail.lines.last(20).join
      end
      production_hint(e, opts)
    end

    # production で credentials / secret_key_base / master key 周りで落ちたときの案内。
    def production_hint(e, opts)
      return unless (opts[:env] || "production") == "production"
      text = "#{e.stderr_tail}\n#{e.message}\n#{e.probe_error && e.probe_error["message"]}"
      return unless text.match?(SECRET_HINT)
      @err.puts "hint: booting with RAILS_ENV=production failed on credentials / secret_key_base / master key."
      @err.puts "  - set SECRET_KEY_BASE_DUMMY=1 (Rails 7.1+) or RAILS_MASTER_KEY in the environment, then re-run"
      @err.puts "  - or measure another environment with --env (e.g. --env staging)"
      @err.puts "  - note: the measurement boots your app with the production configuration, which may connect to external services"
    end
  end
end

# --redact: render の結果 (json / speedscope のみ) のパスを伏せる。既存の render を書き換えずに差し込む。
module Hayate
  module CLIRedact
    private

    def render(result, opts, app_dir = Dir.pwd)
      text = super
      return text unless opts[:redact] && %w[json speedscope].include?(opts[:format])
      require_relative "boot_report/formatters/redact"
      BootReport::Formatters::Redact.new(app_dir: app_dir).apply(text)
    end
  end
  CLI.prepend(CLIRedact)
end
