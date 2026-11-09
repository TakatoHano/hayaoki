# frozen_string_literal: true

module Hayaoki
  module Insitu
    # Resource-limit readers (docs/design/resource-hints.md §2.2). Pure: `root:` / `src` are
    # injectable, every reader returns nil on any error and never raises. Only numbers and fixed
    # tokens are returned (no paths, no kernel string).
    module Limits
      CGROUP_ROOT = "/sys/fs/cgroup"
      MEM_UNLIMITED = 2**60
      # gVisor's fake kernel version line (heuristic). Matched, never logged.
      GVISOR_VERSION = /#1 SMP Sun Jan 10 15:06:54 PST 2016\s*\z/

      module_function

      # "v2" (cgroup.controllers at the root) / "v1" (cpu.cfs_quota_us) / nil
      def cgroup(root: CGROUP_ROOT)
        if File.file?(File.join(root, "cgroup.controllers")) then "v2"
        elsif File.file?(File.join(root, "cpu", "cpu.cfs_quota_us")) then "v1"
        end
      rescue StandardError
        nil
      end

      # Own cgroup path from the "0::/x" line of /proc/self/cgroup ("/" when absent). Never logged.
      # `self_cgroup`: fixture content, or nil to read the file.
      def own_path(self_cgroup = nil)
        text = self_cgroup || read("/proc/self/cgroup")
        line = text.to_s.each_line.find { _1.start_with?("0::") }
        path = line ? line.chomp.delete_prefix("0::") : "/"
        path.start_with?("/") && !path.split("/").include?("..") ? path : "/"
      rescue StandardError
        "/"
      end

      # Directories from the process's own cgroup up to root (root last)
      def chain(root, path)
        parts = path.split("/").reject(&:empty?)
        (0..parts.size).map { |n| File.join(root, *parts.first(parts.size - n)) }
      end

      # CPUs worth of quota (2.0 = two CPUs), nil = unlimited or unknown. v2: tightest cpu.max
      # between the own cgroup and the root.
      def cpu_quota(root: CGROUP_ROOT, self_cgroup: nil)
        case cgroup(root: root)
        when "v2"
          chain(root, own_path(self_cgroup)).filter_map { parse_cpu_max(read(File.join(_1, "cpu.max"))) }.min
        when "v1"
          parse_cfs(read(File.join(root, "cpu", "cpu.cfs_quota_us")), read(File.join(root, "cpu", "cpu.cfs_period_us")))
        end
      rescue StandardError
        nil
      end

      # v2 cpu.max: "<quota|max> <period>"
      def parse_cpu_max(text)
        q, p = text.to_s.split
        return nil if q.nil? || p.nil? || q == "max"
        parse_cfs(q, p)
      rescue StandardError
        nil
      end

      def parse_cfs(quota, period)
        q = Integer(quota.to_s.strip, 10)
        p = Integer(period.to_s.strip, 10)
        return nil if q <= 0 || p <= 0
        (q.to_f / p).round(3)
      rescue ArgumentError, TypeError
        nil
      end

      def mem_max_mb(root: CGROUP_ROOT, self_cgroup: nil)
        if cgroup(root: root) == "v2"
          chain(root, own_path(self_cgroup)).filter_map { parse_mem(read(File.join(_1, "memory.max"))) }.min
        else
          f = File.join(root, "memory", "memory.limit_in_bytes")
          File.file?(f) ? parse_mem(read(f)) : nil
        end
      rescue StandardError
        nil
      end

      # "max", a sentinel (>= 2^60) or garbage -> nil; else whole MiB
      def parse_mem(text)
        s = text.to_s.strip
        return nil if s == "max"
        bytes = Integer(s, 10)
        bytes <= 0 || bytes >= MEM_UNLIMITED ? nil : bytes / (1024 * 1024)
      rescue ArgumentError, TypeError
        nil
      end

      def nproc
        require "etc"
        Etc.nprocessors
      rescue StandardError, LoadError
        nil
      end

      # "gvisor" or nil. `src`: /proc/version content (fixture) or nil to read the file.
      def sandbox(src = nil)
        text = src || read("/proc/version")
        text.to_s.match?(GVISOR_VERSION) ? "gvisor" : nil
      rescue StandardError
        nil
      end

      # Read at load: the fixed part of the line's "limits" object.
      def load_fields(root: CGROUP_ROOT, version_src: nil, self_cgroup: nil)
        {"cgroup" => cgroup(root: root), "cpu_quota" => cpu_quota(root: root, self_cgroup: self_cgroup), "nproc" => nproc,
         "sandbox" => sandbox(version_src)}
      rescue StandardError
        {}
      end

      def read(path)
        File.file?(path) ? File.read(path) : nil
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end
