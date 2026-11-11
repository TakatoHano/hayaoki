# frozen_string_literal: true

module Hayaoki
  module Insitu
    # /proc readers. (Named ProcFS so it does not shadow ::Proc inside Hayaoki::Insitu.)
    # Every reader takes an optional `src`: file content (String containing a newline
    # or not an existing file) or a path to read. Returns nil on failure; never raises.
    module ProcFS
      module_function

      # Field numbers follow proc(5): 3 = state, 12 = majflt, 14 = utime, 15 = stime, 22 = starttime.
      # comm (field 2) may contain spaces and parens, so split after the LAST ")".
      def parse_stat(text)
        text = text.to_s
        open = text.index("(")
        close = text.rindex(")")
        return nil unless open && close && close > open
        rest = text[(close + 1)..].split
        return nil if rest.size < 20
        {
          pid: Integer(text[0...open].strip, 10),
          comm: text[(open + 1)...close],
          state: rest[0],
          ppid: Integer(rest[1], 10),
          majflt: Integer(rest[9], 10),
          utime: Integer(rest[11], 10),
          stime: Integer(rest[12], 10),
          starttime: Integer(rest[19], 10),
        }
      rescue ArgumentError, TypeError
        nil
      end

      # {pid:, comm:, state:, ppid:, majflt:, utime:, stime:, starttime:} (times in clock ticks)
      def self_stat(src = nil) = parse_stat(read(src, "/proc/self/stat"))

      def pid1_stat(src = nil) = parse_stat(read(src, "/proc/1/stat"))

      # VmRSS in kB from /proc/self/status
      def rss_kb(src = nil)
        m = read(src, "/proc/self/status")&.match(/^VmRSS:\s*(\d+)\s*kB/)
        m && m[1].to_i
      end

      # First field of /proc/uptime (seconds since boot) as integer ms
      def uptime_ms(src = nil)
        v = read(src, "/proc/uptime")&.split&.first
        v && Float(v) >= 0 ? (Float(v) * 1000).round : nil
      rescue ArgumentError
        nil
      end

      # Run-queue wait of the main thread in ms: field 2 of /proc/self/schedstat (ns spent runnable
      # but not on a CPU). /proc/<pid>/schedstat is the thread-group leader's own counter, not a sum
      # over threads. nil when the file is missing (non-Linux, kernel without CONFIG_SCHED_INFO,
      # gVisor may not implement it) or malformed.
      def runq_wait_ms(src = nil)
        f = read(src, "/proc/self/schedstat")&.split
        return nil unless f && f.size >= 2
        ns = Integer(f[1], 10)
        ns >= 0 ? ns / 1_000_000.0 : nil
      rescue ArgumentError, TypeError
        nil
      end

      # Major page faults of the process (all threads): field 12 of /proc/self/stat. A major fault
      # had to wait for storage (a page of a mapped file that was not in the page cache).
      def majflt(src = nil)
        v = self_stat(src)&.[](:majflt)
        v && v >= 0 ? v : nil
      end

      # {read_bytes:, rchar:} from /proc/self/io, each nil when its line is missing; nil when the file
      # is unreadable (some sandboxes deny it) or has neither. read_bytes counts bytes fetched from a
      # block device and can stay 0 on overlay, FUSE or virtiofs, so 0 does not mean "no IO". rchar
      # counts bytes passed to read-type system calls (page cache hits included, mmap not).
      def io_bytes(src = nil)
        text = read(src, "/proc/self/io") or return nil
        h = { read_bytes: text[/^read_bytes:\s*(\d+)\s*$/, 1]&.to_i, rchar: text[/^rchar:\s*(\d+)\s*$/, 1]&.to_i }
        h.values.any? ? h : nil
      end

      # Steal time in ms: field 8 of the first "cpu" line of /proc/stat (USER_HZ ticks the hypervisor
      # ran something else while a vCPU had work). System-wide and summed over CPUs, not this process.
      def steal_ms(src = nil, clk_tck: 100)
        f = read(src, "/proc/stat", first_line: true)&.match(/^cpu\s+(.*)$/)&.[](1)&.split
        return nil unless f && f.size >= 8 && clk_tck.to_i > 0
        ticks = Integer(f[7], 10)
        ticks >= 0 ? ticks * 1000.0 / clk_tck : nil
      rescue ArgumentError, TypeError
        nil
      end

      # PSI stall time in ms: `total=` (µs) of the "some" line of /proc/pressure/<resource>
      # ("io" or "cpu"): time in which at least one task was stalled on that resource. System-wide.
      # nil when the kernel has no PSI or it is off (the file is missing or the read fails).
      def psi_some_ms(resource, src = nil)
        v = read(src, "/proc/pressure/#{resource}")&.[](/^some\s.*\btotal=(\d+)/, 1)
        v && v.to_i / 1000.0
      end

      # The counters read at load and again at emit so the report can say what the non-CPU time was
      # (resource-hints.md §2.2.2). Keys are the emit-time names in the line's "proc" object.
      # Five reads (six values); each value is nil on its own when its source is missing.
      WAIT_KEYS = %w[majflt io_read_bytes io_rchar steal_ms psi_io_some_ms psi_cpu_some_ms].freeze

      def wait_counters(clk_tck: 100)
        io = io_bytes
        { "majflt" => majflt, "io_read_bytes" => io && io[:read_bytes], "io_rchar" => io && io[:rchar],
          "steal_ms" => steal_ms(clk_tck: clk_tck),
          "psi_io_some_ms" => psi_some_ms("io"), "psi_cpu_some_ms" => psi_some_ms("cpu") }
      end

      # Age of pid 1 in ms; nil when we are pid 1 (age would equal our own) or unreadable.
      def pid1_age_ms(stat_src = nil, uptime_src = nil, clk_tck: 100, pid: Process.pid)
        return nil if pid == 1
        st = pid1_stat(stat_src)
        up = uptime_ms(uptime_src)
        return nil unless st && up
        age = up - (st[:starttime] * 1000.0 / clk_tck).round
        age >= 0 ? age : nil
      end

      def read(src, default_path, first_line: false)
        return nil if src.nil? && !RUBY_PLATFORM.include?("linux")
        src ||= default_path
        return src if src.include?("\n") || !File.file?(src)
        first_line ? File.open(src, &:gets) : File.read(src)
      rescue SystemCallError, IOError, TypeError
        nil
      end
    end
  end
end
