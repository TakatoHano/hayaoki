# frozen_string_literal: true

require_relative "proc"

module Hayaoki
  module Insitu
    # Marks are floats in ms on one clock: CLOCK_BOOTTIME where available (Linux, so they
    # compare with /proc starttime), otherwise CLOCK_MONOTONIC.
    module Clock
      module_function

      def boottime? = defined?(Process::CLOCK_BOOTTIME) ? true : false

      def now_ms
        id = boottime? ? Process::CLOCK_BOOTTIME : Process::CLOCK_MONOTONIC
        Process.clock_gettime(id, :float_millisecond)
      end

      def realtime_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :float_millisecond)

      # Process CPU time in ms (hint for the VM boot cost)
      def cpu_ms = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID, :float_millisecond)

      def clk_tck
        require "etc"
        Etc.sysconf(Etc::SC_CLK_TCK) || 100
      rescue LoadError, NotImplementedError, NoMethodError, SystemCallError
        100
      end

      # Process start (P1) on the same scale as now_ms, or nil when unavailable
      # (not Linux, no CLOCK_BOOTTIME, unparsable stat, or a value in the future).
      # `stat_src`: fixture content/path for /proc/self/stat; `tck`/`now` are injectable.
      def process_start_ms(stat_src = nil, tck: clk_tck, now: nil)
        return nil unless boottime?
        st = ProcFS.self_stat(stat_src)
        return nil unless st && tck.to_i > 0
        start = st[:starttime] * 1000.0 / tck
        now ||= now_ms
        start <= now ? start : nil
      end

      # Mark -> ms since process start (P1 = 0), nil if either is nil or mark precedes start
      def since_start(mark_ms, start_ms)
        return nil unless mark_ms && start_ms
        d = mark_ms - start_ms
        d >= 0 ? d : nil
      end

      # ISO 8601 UTC (ms) of process start: realtime_now - (boottime_now - start)
      def start_at(start_ms, boot_now: now_ms, real_now: realtime_ms)
        return nil unless start_ms
        Time.at(*(real_now - (boot_now - start_ms)).round.divmod(1000), :millisecond).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end
    end
  end
end
