# frozen_string_literal: true

require_relative "clock"

module Hayaoki
  module Insitu
    @warned = false

    class << self
      attr_reader :state

      # One stderr line per process at most; never raises.
      def warn_once(where, error)
        return if @warned
        @warned = true
        $stderr.puts "[hayaoki insitu] disabled part (#{where}): #{error.class}"
      rescue StandardError
        nil
      end

      # I18n::Backend::Simple#initialized? (nil when I18n or the method is absent).
      # Rails defers the YAML load to the first t() unless something touched I18n during boot.
      def i18n_loaded?
        return nil unless defined?(::I18n) && ::I18n.respond_to?(:backend)
        b = ::I18n.backend
        b.respond_to?(:initialized?) ? b.initialized? : nil
      rescue StandardError
        nil
      end

      # Process CPU ms, nil when the clock is unavailable
      def cpu_ms
        Clock.cpu_ms
      rescue StandardError
        nil
      end

      # Load-time part of the "limits" object (cgroup, cpu_quota, nproc, sandbox); {} on failure
      def read_limits
        require_relative "limits"
        Limits.load_fields
      rescue StandardError, LoadError
        {}
      end

      def gc_time_ms
        GC.stat(:time)
      rescue StandardError
        nil
      end
    end

    # Everything recorded for one boot: raw clock marks (Clock.now_ms scale), eager-load totals,
    # first-request facts and the per-process "already emitted" flag. One instance per process
    # (Insitu.state); tests build their own.
    class State
      MARKS = %i[loaded bundler_require_start bundler_require_end initialize_start initialize_end
                 first_probe first_request_start first_response_end forked].freeze

      attr_reader :id, :load_pid, :load_ms, :start_ms, :entry, :marks, :cpu_marks, :limits, :eager_by, :out, :emit_mode, :probe_hits, :fork_gen
      attr_accessor :boot_error, :i18n_loaded, :first_request, :bootsnap_cache, :eager_ms, :server

      # `start_ms`: process start (P1) on the Clock scale, read once here so a forked worker
      # keeps the start of the process that booted the app (preload_app!). :auto reads /proc.
      def initialize(env: ENV, entry: "boot_rb", load_ms: Clock.now_ms, pid: Process.pid, id: nil, bootsnap_cache: nil,
                     start_ms: :auto, load_cpu_ms: Insitu.cpu_ms, limits: :auto)
        @id = id || Random.urandom(4).unpack1("H*")
        @load_pid = pid
        @load_ms = load_ms
        @start_ms = start_ms == :auto ? Clock.process_start_ms : start_ms
        # nil until initialize! snapshots Insitu.server_process? (false in rake / console / job workers)
        @server = nil
        @entry = entry
        @marks = {loaded: load_ms}
        # Process CPU ms next to each mark (same keys); nil-safe, one Clock.cpu_ms call per mark
        @cpu_marks = {loaded: load_cpu_ms}
        @limits = limits == :auto ? Insitu.read_limits : limits
        @eager_by = Hash.new(0.0)
        @eager_ms = 0.0
        @eager_depth = 0
        @probe_hits = 0
        @fork_gen = 0
        @lock = Mutex.new
        @first_pid = nil
        @emitted_pid = nil
        @forker_pid = nil
        @out = env["HAYAOKI_INSITU_OUT"].to_s.empty? ? "stdout" : env["HAYAOKI_INSITU_OUT"]
        @emit_mode = env["HAYAOKI_INSITU_EMIT"] == "ready" ? "ready" : "first_request"
        # Platform (and the other emit-time files) load lazily to keep boot cost down (§2.3).
        @ignore_env = env.to_h.slice("HAYAOKI_INSITU_IGNORE_PATHS", "AWS_LWA_READINESS_CHECK_PATH")
        @bootsnap_cache = bootsnap_cache
      end

      def ignore_paths
        @ignore_paths ||= begin
          require_relative "platform"
          Platform.ignore_paths(@ignore_env).freeze
        end
      end

      # Keeps the first value: a second Bundler.require or a retried initialize! does not move it.
      def mark(name, t = Clock.now_ms)
        @cpu_marks[name] ||= Insitu.cpu_ms unless @marks.key?(name)
        @marks[name] ||= t
      end

      # A request to an ignored (health) path. Counted only until the first real request starts.
      def probe_hit!(t = Clock.now_ms)
        @lock.synchronize do
          @cpu_marks[:first_probe] ||= Insitu.cpu_ms unless @marks.key?(:first_probe)
          @marks[:first_probe] ||= t
          @probe_hits += 1 unless @first_pid == Process.pid
        end
      end

      # true for exactly one caller per process (Puma threads race here).
      def claim_first_request!
        @lock.synchronize do
          return false if @first_pid == Process.pid
          @first_pid = Process.pid
          true
        end
      end

      def claim_emit!
        @lock.synchronize do
          return false if @emitted_pid == Process.pid
          @emitted_pid = Process.pid
          true
        end
      end

      def emitted? = @emitted_pid == Process.pid

      # Set in the parent by Hooks::ForkHook (pid-scoped, so a child does not inherit it).
      def forked_parent! = (@forker_pid = Process.pid)

      def forked_children? = @forker_pid == Process.pid

      # In a forked child (e.g. a Puma worker after preload): the boot marks are the parent's;
      # this records when the child itself started. First-request facts are per process, so a
      # child forked from a worker that already served (Puma fork_worker) starts them over.
      def forked_in_child!(t = Clock.now_ms)
        @fork_gen = fork_gen + 1 # middleware compares this instead of calling getpid per request
        @marks[:forked] = t
        @cpu_marks[:forked] = Insitu.cpu_ms
        %i[first_probe first_request_start first_response_end].each { |k| @marks.delete(k); @cpu_marks.delete(k) }
        @first_request = nil
        @probe_hits = 0
      end

      # The first request started in this process but its response never finished
      # (body never closed: hijack, a stuck request, or the process was stopped).
      def first_request_incomplete? = @marks.key?(:first_request_start) && !@marks.key?(:first_response_end)

      def worker? = Process.pid != @load_pid

      def recording_eager? = !@marks.key?(:initialize_end)

      # Times the outermost eager-load call only, so nested calls (Rails.eager_load! -> Zeitwerk) are
      # not counted twice. `obj` is a Module (namespace) or a Zeitwerk::Loader (labelled by its tag).
      def eager_span(obj)
        return yield unless recording_eager?
        @eager_depth += 1
        t0 = Clock.now_ms
        begin
          yield
        ensure
          @eager_depth -= 1
          if @eager_depth.zero?
            d = Clock.now_ms - t0
            @eager_ms += d
            @eager_by[eager_label(obj)] += d
          end
        end
      end

      def eager_label(obj)
        obj.is_a?(Module) ? obj.name.to_s : obj.tag.to_s
      rescue StandardError
        "?"
      end
    end
  end
end
