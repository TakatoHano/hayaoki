# frozen_string_literal: true

require "json"
require_relative "../../hayate"
require "tmpdir"
require "fileutils"

module Hayate
  module BootReport
    PROBE_PATH = File.expand_path("../probe.rb", __dir__)

    # 子プロセスの失敗。stderr の末尾と、あれば部分結果 (payload) を持つ。
    class RunError < Hayate::Error
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

      # 基準実行は entry の require 直後の実時刻を一時ファイル (HAYATE_BASE_MARK) に書く。
      def script(probe)
        req = "require File.expand_path(#{entry.inspect}, Dir.pwd)"
        return req if probe
        "#{req}; File.write(ENV.fetch('HAYATE_BASE_MARK'), Process.clock_gettime(Process::CLOCK_REALTIME).to_s)"
      end

      # RunError を raise する場合がある。
      def run
        conditions = bootsnap == :both ? %i[warm cold] : [bootsnap]
        payloads = {}
        overhead = {}
        warnings = []
        Dir.mktmpdir("hayate-run") do |tmp|
          @tmp = tmp
          @seq = 0
          conditions.each do |cond|
            payloads[cond.to_s], overhead[cond] = measure(cond, warnings)
          end
        end
        meta = {
          "app_dir" => app_dir, "runs" => runs, "env" => env, "bootsnap" => bootsnap.to_s, "ruby" => ruby,
          "entry" => entry, "conditions" => conditions.map(&:to_s), "warnings" => warnings.uniq,
          "overhead" => overhead.transform_keys(&:to_s),
        }
        RunResult.new(payloads, meta)
      end

      private

      def measure(cond, warnings)
        warm_dir = cond == :warm ? new_dir("cache-warm") : nil
        # ウォームアップ (捨てる 1 回): OS のファイルキャッシュと、warm 条件では bootsnap のキャッシュを温める
        progress(:warmup, cond, 0)
        execute(probe: true, cache_dir: warm_dir || new_dir("cache-cold"))
        results = []
        base_ms = []
        cache_used = false
        runs.times do |i|
          cache = warm_dir || new_dir("cache-cold")
          progress(:probe, cond, i + 1)
          results << execute(probe: true, cache_dir: cache)[:payload]
          cache_used ||= !Dir.empty?(cache)
          progress(:baseline, cond, i + 1)
          base_ms << (execute(probe: false, cache_dir: warm_dir || new_dir("cache-cold"))[:boot_ms])
        end
        cache_used ||= !Dir.empty?(warm_dir) if warm_dir
        unless cache_used
          warnings << "[#{cond}] BOOTSNAP_CACHE_DIR was not used (the app may call Bootsnap.setup with its own cache_dir, or bootsnap is not loaded); bootsnap #{cond} measurement may not be meaningful"
        end
        [results, overhead(results, base_ms)]
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
        out = File.join(@tmp, "out-#{@seq += 1}.json")
        errf = File.join(@tmp, "err-#{@seq}.log")
        child_env = { "RAILS_ENV" => env, "RACK_ENV" => env, "BOOTSNAP_CACHE_DIR" => cache_dir, "DISABLE_SPRING" => "1" }
        mark = File.join(@tmp, "mark-#{@seq}.txt")
        child_env["HAYATE_PROBE_OUT"] = out if probe
        child_env["HAYATE_BASE_MARK"] = mark unless probe
        pid = nil
        t0 = nil
        spawn_real = nil
        with_clean_env do |base|
          e = base.merge(child_env)
          e["HAYATE_SPAWN_AT"] = nil
          opts = { chdir: app_dir, in: File::NULL, out: File::NULL, err: errf, pgroup: true }
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          spawn_real = Process.clock_gettime(Process::CLOCK_REALTIME)
          e["HAYATE_SPAWN_AT"] = spawn_real.to_s if probe
          pid = Process.spawn(e, *command(probe: probe), **opts)
        end
        status, timed_out = wait(pid)
        wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        tail = read_tail(errf)
        payload = File.exist?(out) ? parse(out) : nil

        if timed_out
          raise RunError.new(:timeout, "boot did not finish within #{timeout}s (killed)", stderr_tail: tail, partial: payload)
        end
        unless status.success?
          raise RunError.new(payload ? :boot_error : :exit_status, "child exited with status #{status.exitstatus.inspect}#{status.signaled? ? " (signal #{status.termsig})" : ""}",
                             stderr_tail: tail, partial: payload, exit_status: status.exitstatus)
        end
        if probe
          if payload.nil?
            raise RunError.new(:no_output, "probe wrote no output (the app may have called exit!/exec, or replaced the process)", stderr_tail: tail, exit_status: 0)
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
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
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

      # アプリ側の Bundler 環境を持ち込まない。ブロックには環境変数の Hash を渡す (spawn はこの中で行う)。
      def with_clean_env(&block)
        if bundler_available?
          ::Bundler.with_unbundled_env { block.call(ENV.to_h) }
        else
          block.call(strip_bundler(ENV.to_h))
        end
      end

      def bundler_available?
        return true if defined?(::Bundler) && ::Bundler.respond_to?(:with_unbundled_env)
        require "bundler"
        ::Bundler.respond_to?(:with_unbundled_env)
      rescue LoadError
        false
      end

      def strip_bundler(h)
        h = h.reject { |k, _| k.start_with?("BUNDLE_") || k.start_with?("BUNDLER_") }
        h.delete("RUBYLIB") if h["RUBYLIB"].to_s.include?("bundler")
        if (ro = h["RUBYOPT"])
          kept = ro.split(/\s+/).reject { |t| t.include?("bundler") }
          kept.empty? ? h.delete("RUBYOPT") : h["RUBYOPT"] = kept.join(" ")
        end
        h
      end
    end
  end
end
