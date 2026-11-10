# frozen_string_literal: true

require_relative "../mini_json"
require_relative "../version"
require_relative "clock"
require_relative "proc"
require_relative "platform"
require_relative "state"

module Hayaoki
  module Insitu
    # Builds the v1 line (phase2.md §3.1) and writes it once per process.
    module Emitter
      TOP_EAGER = 5
      # Largest believable process start -> hayaoki load gap. Lambda init is capped at 10 s and a
      # Cloud Run startup probe allows at most 600 s for the whole startup, of which pre_load is a part.
      # A gap beyond this is not a boot (seen on Cloud Run gen1: a 2 h gap between /proc starttime and the
      # load mark), so the line falls back to the load origin and reports the rejected value.
      MAX_PRE_LOAD_MS = 600_000

      module_function

      # status: "ok" | "no_request" | "incomplete" | "boot_error". Returns the line, or nil when this process
      # already emitted or something failed (then one stderr warning).
      def emit(state, status)
        return nil unless state&.claim_emit!
        line = MiniJSON.encode(build(state, status))
        write(state.out, line)
        line
      rescue StandardError => e
        Insitu.warn_once("emit", e)
        nil
      end

      def write(out, line)
        case out
        when "stdout" then io_write($stdout, line)
        when "stderr" then io_write($stderr, line)
        else File.open(out, "a") { |f| f.write("#{line}\n") }
        end
      end

      def io_write(io, line)
        io.write("#{line}\n")
        io.flush
      end

      # `start_ms`: process start on the Clock scale (nil = unknown -> origin is the hayaoki load).
      # :auto uses State#start_ms (read at load, so a preloaded worker measures from the master's start).
      # `facts`: the "proc" object; injectable for tests.
      def build(state, status, start_ms: :auto, facts: nil, env: ENV)
        features = $LOADED_FEATURES.size
        start_ms = state.start_ms if start_ms == :auto
        rejected = start_rejection(start_ms, state.marks[:loaded] || state.load_ms)
        start_ms = nil if rejected
        origin = start_ms || state.load_ms
        m = State::MARKS.to_h { |k| [k.to_s, ms(Clock.since_start(state.marks[k], origin))] }

        fp = m["first_probe"]
        frs = m["first_request_start"]
        fre = m["first_response_end"]
        if fp && (frs.nil? || fp <= frs)
          ready = fp
          ready_source = "probe"
        elsif m["initialize_end"]
          ready = m["initialize_end"]
          ready_source = "initialize"
        end

        phases = {
          "pre_load" => start_ms ? m["loaded"] : nil,
          "pre_bundler" => diff(m["loaded"], m["bundler_require_start"]),
          "bundler_require" => diff(m["bundler_require_start"], m["bundler_require_end"]),
          "app_config" => diff(m["bundler_require_end"], m["initialize_start"]),
          "initialize" => diff(m["initialize_start"], m["initialize_end"]),
          "eager_load" => state.eager_by.empty? ? nil : ms(state.eager_ms),
          "to_ready" => ready,
          "idle" => diff(ready, frs),
          "first_request" => diff(frs, fre),
          "to_first_response" => fre,
        }

        cpu = cpu_phases(state, ready_source)

        h = {
          "hayaoki" => "cold_start", "v" => 1,
          "severity" => status == "boot_error" ? "ERROR" : "INFO",
          "message" => message(status, ready, fre),
          "status" => status,
        }
        h["error_class"] = state.boot_error if state.boot_error
        h.merge!(
          "id" => state.id, "pid" => Process.pid, "worker" => state.worker?,
          "start_at" => Clock.start_at(start_ms), "start_source" => start_ms ? "proc_stat" : "load",
          "ready_source" => ready_source,
        )
        h["start_rejected"] = rejected if rejected
        h.merge!(
          "platform" => Platform.fields(env),
          "runtime" => runtime(state, env),
          "marks_ms" => m,
          "phases_ms" => phases,
          "phases_cpu_ms" => cpu,
          "eager_top" => state.eager_by.sort_by { |_, v| -v }.first(TOP_EAGER).map { |k, v| [k, ms(v)] },
          "first_request" => state.first_request,
          "proc" => facts || proc_facts(state, features, Clock.clk_tck),
          "limits" => limits(state),
        )
        h
      end

      # CPU ms over the spans of the matching phases_ms entries (load_* start at the loaded mark).
      # In a forked child the CPU clock restarts, so a span ending in the child has no value.
      def cpu_phases(state, ready_source)
        c = state.cpu_marks
        child = state.marks.key?(:forked)
        ready_key = ready_source == "probe" ? :first_probe : (ready_source == "initialize" ? :initialize_end : nil)
        {
          "bundler_require" => ms(diff(c[:bundler_require_start], c[:bundler_require_end])),
          "initialize" => ms(diff(c[:initialize_start], c[:initialize_end])),
          "load_to_ready" => ready_key && !(child && ready_key == :first_probe) ? ms(diff(c[:loaded], c[ready_key])) : nil,
          "load_to_first_response" => child ? nil : ms(diff(c[:loaded], c[:first_response_end])),
        }
      end

      # load-time fields from State plus mem_max_mb read now; key order as in the design
      def limits(state)
        l = state.limits || {}
        require_relative "limits"
        {"cgroup" => l["cgroup"], "cpu_quota" => l["cpu_quota"], "nproc" => l["nproc"],
         "mem_max_mb" => Limits.mem_max_mb, "sandbox" => l["sandbox"]}
      rescue StandardError, LoadError
        nil
      end

      # nil when start_ms is usable as the origin; otherwise {"reason", "pre_load_ms"} for the line
      def start_rejection(start_ms, loaded_ms)
        return nil unless start_ms && loaded_ms
        gap = loaded_ms - start_ms
        return nil if gap >= 0 && gap <= MAX_PRE_LOAD_MS
        {"reason" => gap.negative? ? "start_after_load" : "pre_load_over_limit", "pre_load_ms" => ms(gap)}
      end

      def message(status, ready, fre)
        case status
        when "boot_error" then "hayaoki cold start: boot error"
        when "no_request" then "hayaoki cold start: ready #{ready || "?"}ms, no request"
        when "incomplete" then "hayaoki cold start: ready #{ready || "?"}ms, first response not finished"
        else
          # HAYAOKI_INSITU_EMIT=ready emits before any request: no "first response" part
          fre ? "hayaoki cold start: ready #{ready || "?"}ms, first response #{fre}ms" : "hayaoki cold start: ready #{ready || "?"}ms"
        end
      end

      def runtime(state, env)
        {
          "ruby" => RUBY_VERSION, "rails" => rails_version, "hayaoki" => Hayaoki::VERSION,
          "yjit" => yjit?, "env" => app_env(env),
          "bootsnap" => defined?(::Bootsnap) ? true : false, "bootsnap_cache" => state.bootsnap_cache,
          "eager_load" => eager_load?, "entry" => state.entry,
        }
      end

      # The *_at_load_ms values are nil in a forked child: its CPU clock and its schedstat counters
      # restart at fork, so the load-time reading belongs to another process.
      def proc_facts(state, features, tck)
        child = state.marks.key?(:forked)
        {
          "cpu_ms" => ms(Clock.cpu_ms), "cpu_at_load_ms" => child ? nil : ms(state.cpu_marks[:loaded]), "rss_kb" => ProcFS.rss_kb, "uptime_ms" => ProcFS.uptime_ms,
          "pid1_age_ms" => ProcFS.pid1_age_ms(clk_tck: tck),
          # main thread only (/proc/self/schedstat is the thread-group leader's counter; see resource-hints.md §2.2)
          "main_thread_runq_wait_ms" => ms(ProcFS.runq_wait_ms),
          "main_thread_runq_wait_at_load_ms" => child ? nil : ms(state.load_runq_wait_ms),
          "gc_count" => GC.count, "gc_time_ms" => Insitu.gc_time_ms, "features" => features,
          "i18n_loaded" => state.i18n_loaded.nil? ? Insitu.i18n_loaded? : state.i18n_loaded,
        }
      end

      def rails_version
        defined?(::Rails) && ::Rails.respond_to?(:version) ? ::Rails.version.to_s : nil
      rescue StandardError
        nil
      end

      def app_env(env)
        return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env)
        e = env["RAILS_ENV"]
        e.nil? || e.empty? ? env["RACK_ENV"] : e
      rescue StandardError
        nil
      end

      def eager_load?
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
        ::Rails.application.config.eager_load ? true : false
      rescue StandardError
        nil
      end

      def yjit?
        defined?(::RubyVM::YJIT) && ::RubyVM::YJIT.respond_to?(:enabled?) ? ::RubyVM::YJIT.enabled? : false
      end

      def diff(a, b) = a && b ? b - a : nil

      def ms(v) = v&.round
    end
  end
end
