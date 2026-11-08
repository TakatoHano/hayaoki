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
          "platform" => Platform.fields(env),
          "runtime" => runtime(state, env),
          "marks_ms" => m,
          "phases_ms" => phases,
          "eager_top" => state.eager_by.sort_by { |_, v| -v }.first(TOP_EAGER).map { |k, v| [k, ms(v)] },
          "first_request" => state.first_request,
          "proc" => facts || proc_facts(state, features, Clock.clk_tck),
        )
        h
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

      def proc_facts(state, features, tck)
        {
          "cpu_ms" => ms(Clock.cpu_ms), "rss_kb" => ProcFS.rss_kb, "uptime_ms" => ProcFS.uptime_ms,
          "pid1_age_ms" => ProcFS.pid1_age_ms(clk_tck: tck),
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
