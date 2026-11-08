# frozen_string_literal: true

require "json"
require_relative "../../hayaoki"
require "tmpdir"
require "fileutils"

module Hayaoki
  module BootReport
    PROBE_PATH = File.expand_path("../probe.rb", __dir__)

    # 子プロセスの失敗。stderr の末尾と、あれば部分結果 (payload) を持つ。
    class RunError < Hayaoki::Error
      attr_reader :reason, :stderr_tail, :partial, :exit_status, :open_span, :probe_error

      # reason: :exit_status / :no_output / :timeout / :boot_error
      def initialize(reason, summary, stderr_tail: "", partial: nil, exit_status: nil)
        @reason = reason
        @stderr_tail = stderr_tail.to_s
        @partial = partial
        @exit_status = exit_status
        @probe_error = partial && partial["error"]
        @open_span = partial && RunError.find_open_span(partial)
        super(build_message(summary))
      end

      # 最後に開いていた span (未完了のうち最も深いもの、無ければ最後の raised)。
      def self.find_open_span(payload)
        w = payload["width"] || 8
        ev = payload["events"] || []
        open = nil
        raised = nil
        (0...(ev.size / w)).each do |i|
          kind, name, _par, _t0, t1, res = ev[i * w, 6]
          open = [kind, name] if t1.nil?
          raised = [kind, name] if res == "raised"
        end
        found = open || raised
        found && { "kind" => found[0], "name" => found[1] }
      end

      private

      def build_message(summary)
        msg = +summary
        if @probe_error
          msg << "\nerror: #{@probe_error["class"]}: #{@probe_error["message"]}"
        end
        msg << "\nlast open span: kind=#{@open_span["kind"]} #{@open_span["name"]}" if @open_span
        msg << "\n--- stderr (tail) ---\n#{@stderr_tail}" unless @stderr_tail.empty?
        msg
      end
    end

    # 条件ごと ("warm" / "cold") の payload の配列と、メタデータ。
    class RunResult
      attr_reader :payloads, :meta

      def initialize(payloads, meta)
        @payloads = payloads
        @meta = meta
      end

      def conditions = payloads.keys
    end

    class Runner
      STDERR_TAIL_BYTES = 4096
      KILL_GRACE = 3.0
      BOOTSNAP_MODES = %i[warm cold both].freeze

      attr_reader :app_dir, :runs, :env, :bootsnap, :ruby, :entry, :timeout

      def initialize(app_dir:, runs: 5, env: "production", bootsnap: :warm, ruby: "ruby", entry: "config/environment", timeout: 120, on_progress: nil)
        raise ArgumentError, "bootsnap must be one of #{BOOTSNAP_MODES.inspect}" unless BOOTSNAP_MODES.include?(bootsnap)
        raise ArgumentError, "runs must be >= 1" unless runs.is_a?(Integer) && runs >= 1
        @app_dir = File.expand_path(app_dir)
        @runs = runs
        @env = env
        @bootsnap = bootsnap
        @ruby = ruby
        @entry = entry
        @timeout = timeout
        @on_progress = on_progress
      end

      def command(probe: true)
        [ruby, *(probe ? ["-r", PROBE_PATH] : []), "-e", script(probe)]
      end

      # 基準実行は entry の require 直後の実時刻を一時ファイル (HAYAOKI_BASE_MARK) に書く。
      def script(probe)
        req = "require File.expand_path(#{entry.inspect}, Dir.pwd)"
        return req if probe
        "#{req}; File.write(ENV.fetch('HAYAOKI_BASE_MARK'), Process.clock_gettime(Process::CLOCK_REALTIME).to_s)"
      end

      # 全 run が失敗した場合 (条件ごと) などに RunError を raise する。一部の run の失敗は meta["failed_runs"] に記録して続行する。
      def run
        check_app!
        check_ruby!
        @gemfile_present = nil
        gemfile_present?
        conditions = bootsnap == :both ? %i[warm cold] : [bootsnap]
        payloads = {}
        overhead = {}
        warnings = []
        @failures = []
        @interrupted = nil
        @child = nil
        old_traps = install_traps
        begin
          Dir.mktmpdir("hayaoki-run") do |tmp|
            @tmp = tmp
            @seq = 0
            conditions.each do |cond|
              payloads[cond.to_s], ov = measure(cond, warnings)
              overhead[cond] = ov if ov
            end
          end
        rescue Interrupted
          # 子の後始末は済んでいる。元の trap に戻してから、そのシグナルを元のハンドラに渡す
          olds = old_traps
          old_traps = nil
          restore_traps(olds)
          redeliver(@interrupted, olds[Signal.signame(@interrupted)])
          raise RunError.new(:interrupted, "interrupted by SIG#{Signal.signame(@interrupted)}")
        ensure
          restore_traps(old_traps) if old_traps
        end
        meta = {
          "app_dir" => app_dir, "runs" => runs, "env" => env, "bootsnap" => bootsnap.to_s, "ruby" => ruby,
          "entry" => entry, "conditions" => conditions.map(&:to_s), "warnings" => warnings.uniq,
          "overhead" => overhead.transform_keys(&:to_s), "failed_runs" => @failures,
        }
        RunResult.new(payloads, meta)
      end

      private

      def measure(cond, warnings)
        warm_dir = cond == :warm ? new_dir("cache-warm") : nil
        # ウォームアップ (捨てる 1 回): OS のファイルキャッシュと、warm 条件では bootsnap のキャッシュを温める
        progress(:warmup, cond, 0)
        guarded(cond, :warmup, 0) { execute(probe: true, cache_dir: warm_dir || new_dir("cache-cold")) }
        results = []
        base_ms = []
        cache_used = false
        first_error = nil
        runs.times do |i|
          cache = warm_dir || new_dir("cache-cold")
          progress(:probe, cond, i + 1)
          r = guarded(cond, :probe, i + 1) { execute(probe: true, cache_dir: cache) }
          if r.is_a?(RunError)
            first_error ||= r
            results << failed_payload(r)
          else
            results << r[:payload]
          end
          cache_used ||= !Dir.empty?(cache)
          progress(:baseline, cond, i + 1)
          b = guarded(cond, :baseline, i + 1) { execute(probe: false, cache_dir: warm_dir || new_dir("cache-cold")) }
          base_ms << b[:boot_ms] unless b.is_a?(RunError)
        end
        ok = results.select { |p| p["status"] == "ok" }
        if ok.empty?
          # 全ての run が失敗: 最初の失敗を (記録済みの内容ごと) 返して終了する
          raise first_error
        end
        cache_used ||= !Dir.empty?(warm_dir) if warm_dir
        unless cache_used
          warnings << "[#{cond}] BOOTSNAP_CACHE_DIR was not used (the app may call Bootsnap.setup with its own cache_dir, or bootsnap is not loaded); bootsnap #{cond} measurement may not be meaningful"
        end
        [results, base_ms.empty? ? nil : overhead(ok, base_ms)]
      end

      # RunError を meta 用に記録して返す (Interrupted は素通し)。成功ならブロックの値。
      def guarded(cond, phase, index)
        yield
      rescue RunError => e
        @failures << { "condition" => cond.to_s, "phase" => phase.to_s, "index" => index, "reason" => e.reason.to_s,
                       "message" => e.message.lines.first.to_s.strip, "exit_status" => e.exit_status,
                       "error_class" => e.probe_error && e.probe_error["class"], "stderr_tail" => e.stderr_tail }
        e
      end

      # 失敗した run を集計側が除外できる形 (status が ok 以外) にする。
      def failed_payload(err)
        base = err.partial.is_a?(Hash) ? err.partial.dup : {}
        base["status"] = "failed" if base["status"].nil? || base["status"] == "ok"
        base["failure_reason"] = err.reason.to_s
        base
      end

      # index: warmup は 0、probe / baseline は 1 始まり。total は計測 run 数。
      def progress(phase, cond, index)
        @on_progress&.call({ "phase" => phase, "bootsnap" => cond, "index" => index, "total" => runs })
      end

      def overhead(payloads, base_ms)
        probe_ms = payloads.map do |p|
          boot_us = p["boot_end_us"] || p["exit_us"]
          lead = p["spawn_at"] ? (p["t0_real"] - p["spawn_at"].to_f) * 1000.0 : 0.0
          lead + boot_us / 1000.0
        end
        b = median(base_ms)
        p = median(probe_ms)
        { "baseline_ms" => b.round(3), "probe_ms" => p.round(3), "diff_ms" => (p - b).round(3), "ratio" => b.positive? ? (p / b).round(4) : nil,
          "baseline_samples_ms" => base_ms.map { _1.round(3) }, "probe_samples_ms" => probe_ms.map { _1.round(3) } }
      end

      def median(a)
        s = a.sort
        n = s.size
        n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
      end

      def new_dir(prefix)
        d = File.join(@tmp, "#{prefix}-#{@seq += 1}")
        FileUtils.mkdir_p(d)
        d
      end

      # 1 回実行する。probe 有りなら payload を読んで返す。{ payload:, wall: }
      def execute(probe:, cache_dir:)
        pid = nil
        run_child(probe: probe, cache_dir: cache_dir) { |p| pid = p }
      ensure
        reap_group(pid) if pid
      end

      def run_child(probe:, cache_dir:)
        raise Interrupted if @interrupted
        out = File.join(@tmp, "out-#{@seq += 1}.json")
        errf = File.join(@tmp, "err-#{@seq}.log")
        child_env = { "RAILS_ENV" => env, "RACK_ENV" => env, "BOOTSNAP_CACHE_DIR" => cache_dir, "DISABLE_SPRING" => "1" }
        mark = File.join(@tmp, "mark-#{@seq}.txt")
        child_env["HAYAOKI_PROBE_OUT"] = out if probe
        child_env["HAYAOKI_BASE_MARK"] = mark unless probe
        child_env["BUNDLE_FROZEN"] = "true" if gemfile_present?
        pid = nil
        t0 = nil
        spawn_real = nil
        with_clean_env do |base|
          e = base.merge(child_env)
          e["HAYAOKI_SPAWN_AT"] = nil
          opts = { chdir: app_dir, in: File::NULL, out: File::NULL, err: errf, pgroup: true }
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          spawn_real = Process.clock_gettime(Process::CLOCK_REALTIME)
          e["HAYAOKI_SPAWN_AT"] = spawn_real.to_s if probe
          pid = Process.spawn(e, *command(probe: probe), **opts)
          @child = pid
          yield pid
        end
        status, timed_out = wait(pid)
        @child = nil
        @reaped_pid = pid
        raise Interrupted if @interrupted
        wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        tail = read_tail(errf)
        payload = File.exist?(out) ? parse(out) : nil
        corrupt = payload.nil? && File.exist?(out)

        if timed_out
          raise RunError.new(:timeout, "boot did not finish within #{timeout}s (killed)", stderr_tail: tail, partial: payload)
        end
        unless status.success?
          raise RunError.new(payload ? :boot_error : :exit_status, "child exited with status #{status.exitstatus.inspect}#{status.signaled? ? " (signal #{status.termsig})" : ""}",
                             stderr_tail: tail, partial: payload, exit_status: status.exitstatus)
        end
        if probe
          if payload.nil?
            msg = if corrupt
                    "probe output was not valid JSON (the file was truncated or overwritten, e.g. the app wrote to HAYAOKI_PROBE_OUT or the process was killed while writing)"
                  else
                    "probe wrote no output (the app may have called exit!/exec, or replaced the process)"
                  end
            raise RunError.new(:no_output, msg, stderr_tail: tail, exit_status: 0)
          end
          if payload["status"] != "ok"
            raise RunError.new(:boot_error, "boot failed (probe status=#{payload["status"]})", stderr_tail: tail, partial: payload, exit_status: 0)
          end
        end
        boot_ms = nil
        unless probe
          end_at = (Float(File.read(mark)) rescue nil)
          raise RunError.new(:no_output, "baseline run did not reach the end of entry (marker missing)", stderr_tail: tail, exit_status: 0) unless end_at
          boot_ms = (end_at - spawn_real) * 1000.0
        end
        { payload: payload, wall: wall, boot_ms: boot_ms }
      end

      def parse(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def read_tail(path)
        File.open(path, "rb") do |f|
          size = f.size
          f.seek([size - STDERR_TAIL_BYTES, 0].max)
          f.read.to_s.scrub
        end
      rescue SystemCallError
        ""
      end

      # [Process::Status, timed_out]
      def wait(pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          r = Process.wait2(pid, Process::WNOHANG)
          return [r[1], false] if r
          break if @interrupted || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.005
        end
        # SIGTERM で probe に部分結果を書かせ、だめなら KILL
        signal_group("TERM", pid)
        grace = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE
        until (r = Process.wait2(pid, Process::WNOHANG))
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > grace
            signal_group("KILL", pid)
            return [Process.wait2(pid)[1], true]
          end
          sleep 0.01
        end
        [r[1], true]
      end

      def signal_group(sig, pid)
        Process.kill(sig, -pid)
      rescue SystemCallError
        begin
          Process.kill(sig, pid)
        rescue SystemCallError
          nil
        end
      end

      # 内部用: シグナルで中断された (子の後始末は済んでいる)。
      class Interrupted < StandardError; end

      def check_app!
        return if File.directory?(app_dir)
        raise RunError.new(:app_dir, "APP_DIR not found: #{app_dir}")
      end

      MIN_RUBY = Gem::Version.new("3.2")

      # 子プロセスの ruby (既定は PATH 上の ruby。rbenv などはアプリのディレクトリで版を選ぶ) が probe を読めるか。
      # 古い ruby だと probe の構文エラーが大量に出るだけで原因が分からないので、先に版を確かめる。
      def check_ruby!
        out, st = with_clean_env do |base|
          IO.popen(base, [ruby, "-e", "print RUBY_VERSION"], chdir: app_dir, err: File::NULL, &:read).then { [_1, $?] }
        end
        v = out.to_s.strip
        raise RunError.new(:ruby, "could not run `#{ruby} -e 'print RUBY_VERSION'` in #{app_dir}") unless st&.success? && v.match?(/\A\d+\.\d+/)
        return if Gem::Version.new(v) >= MIN_RUBY
        raise RunError.new(:ruby, "`#{ruby}` in #{app_dir} is Ruby #{v}, but the probe needs Ruby #{MIN_RUBY} or later. " \
                                  "Pass the app's ruby with --ruby PATH, or fix PATH / .ruby-version.")
      rescue SystemCallError => e
        raise RunError.new(:ruby, "ruby executable not found: #{ruby} (#{e.class}). Pass it with --ruby PATH.")
      end

      # Gemfile があるアプリは Gemfile.lock が必須 (子に BUNDLE_FROZEN=true を渡すので、lock の生成・更新をさせない)。
      def gemfile_present?
        return @gemfile_present unless @gemfile_present.nil?
        gemfile = with_clean_env { |base| base["BUNDLE_GEMFILE"].to_s.empty? ? File.join(app_dir, "Gemfile") : File.expand_path(base["BUNDLE_GEMFILE"], app_dir) }
        @gemfile_present = File.file?(gemfile)
        if @gemfile_present
          lock = "#{gemfile}.lock"
          unless File.file?(lock)
            raise RunError.new(:no_lockfile, "#{lock} not found. hayaoki does not modify your app, so run `bundle lock` in #{app_dir} first (or `bundle install`).")
          end
        end
        @gemfile_present
      end

      def install_traps
        %w[INT TERM].to_h do |name|
          signo = Signal.list.fetch(name)
          old = Signal.trap(name) do
            @interrupted ||= signo
            signal_group("TERM", @child) if @child
          end
          [name, old]
        end
      end

      def restore_traps(olds)
        olds.each { |name, old| Signal.trap(name, old || "DEFAULT") }
      end

      # 元のハンドラに、受け取ったシグナルを渡す。DEFAULT ならそのシグナルで自分が終了する (終了ステータスが保たれる)。
      def redeliver(signo, old)
        name = Signal.signame(signo)
        case old
        when Proc then old.call(signo)
        when "DEFAULT", "SYSTEM_DEFAULT", nil, ""
          Signal.trap(name, "DEFAULT")
          Process.kill(name, Process.pid)
          sleep 1 # シグナルが配送されるまで
        end
      end

      # 子のプロセスグループが残っていれば TERM → 猶予 → KILL で片付け、回収する。
      def reap_group(pid)
        return if @reaped_pid == pid
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE
        signal_group("TERM", pid)
        loop do
          begin
            r = Process.wait2(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            break
          end
          break if r
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            signal_group("KILL", pid)
            Process.wait2(pid) rescue nil
            break
          end
          sleep 0.01
        end
        @reaped_pid = pid
      end

      # アプリ側の bundle exec が注入したものだけを除く。利用者が設定した BUNDLE_* (BUNDLE_WITHOUT / GEMFILE / PATH / DEPLOYMENT など) は残す。
      # ブロックには環境変数の Hash を渡す (spawn はこの中で行う)。
      def with_clean_env(&block)
        if defined?(::Bundler) && ::Bundler.respond_to?(:with_original_env)
          ::Bundler.with_original_env { block.call(strip_injected(ENV.to_h)) }
        else
          block.call(strip_injected(ENV.to_h))
        end
      end

      def bundler_lib_dirs
        dirs = []
        if defined?(::Bundler) && ::Bundler.respond_to?(:with_original_env)
          loc = ::Bundler.method(:with_original_env).source_location
          dirs << File.dirname(loc[0]) if loc
        end
        dirs
      end

      def strip_injected(h)
        h = h.reject { |k, _| %w[BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION BUNDLER_ORIG_RUBYOPT BUNDLER_ORIG_RUBYLIB].include?(k) }
        if (rl = h["RUBYLIB"])
          dirs = bundler_lib_dirs
          kept = rl.split(File::PATH_SEPARATOR).reject { |d| dirs.include?(d) || d =~ %r{/bundler[^/]*/lib/?\z} }
          kept.empty? ? h.delete("RUBYLIB") : h["RUBYLIB"] = kept.join(File::PATH_SEPARATOR)
        end
        if (ro = h["RUBYOPT"])
          toks = ro.split(/\s+/).reject(&:empty?)
          kept = []
          until toks.empty?
            t = toks.shift
            if t == "-r" && toks.first == "bundler/setup"
              toks.shift
            elsif t != "-rbundler/setup"
              kept << t
            end
          end
          kept.empty? ? h.delete("RUBYOPT") : h["RUBYOPT"] = kept.join(" ")
        end
        h
      end
    end
  end
end
