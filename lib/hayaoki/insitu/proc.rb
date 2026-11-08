# frozen_string_literal: true

module Hayaoki
  module Insitu
    # /proc readers. (Named ProcFS so it does not shadow ::Proc inside Hayaoki::Insitu.)
    # Every reader takes an optional `src`: file content (String containing a newline
    # or not an existing file) or a path to read. Returns nil on failure; never raises.
    module ProcFS
      module_function

      # Field numbers follow proc(5): 3 = state, 14 = utime, 15 = stime, 22 = starttime.
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
          utime: Integer(rest[11], 10),
          stime: Integer(rest[12], 10),
          starttime: Integer(rest[19], 10),
        }
      rescue ArgumentError, TypeError
        nil
      end

      # {pid:, comm:, state:, ppid:, utime:, stime:, starttime:} (times in clock ticks)
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

      # Age of pid 1 in ms; nil when we are pid 1 (age would equal our own) or unreadable.
      def pid1_age_ms(stat_src = nil, uptime_src = nil, clk_tck: 100, pid: Process.pid)
        return nil if pid == 1
        st = pid1_stat(stat_src)
        up = uptime_ms(uptime_src)
        return nil unless st && up
        age = up - (st[:starttime] * 1000.0 / clk_tck).round
        age >= 0 ? age : nil
      end

      def read(src, default_path)
        return nil if src.nil? && !RUBY_PLATFORM.include?("linux")
        src ||= default_path
        return src if src.include?("\n") || !File.file?(src)
        File.read(src)
      rescue SystemCallError, IOError, TypeError
        nil
      end
    end
  end
end
