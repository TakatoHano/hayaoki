# frozen_string_literal: true

require_relative "stats"

module Hayaoki
  module ColdStartReport
    # Hints: short "likely" statements about causes outside the app code, each with the numbers
    # behind it. Computed from the lines only (docs/design/resource-hints.md §3).
    module Hints
      MIN_N = 3              # G_n
      MIN_READY_MS = 3000    # G_ready: ready p50
      LEVELS = %w[likely possible note].freeze
      MIXED_KEYS = %w[platform.revision platform.memory_mb limits.cpu_quota runtime.bootsnap].freeze

      Hint = Struct.new(:id, :level, :n, :mixed, :evidence, :message, :cannot_see, keyword_init: true) do
        def to_h
          { "id" => id, "level" => level, "n" => n, "mixed" => mixed, "evidence" => evidence,
            "message" => message, "cannot_see" => cannot_see }
        end
      end

      # What a rule can read. platform: Lambda Init durations and INIT_REPORT counts, nil when they
      # cannot be tied to this set (--group-by with more than one Lambda group).
      class Context
        attr_reader :ok, :ok_p, :mixed, :init_ms, :init_reports

        def initialize(records, init_ms: nil, init_reports: nil)
          @ok = records.select { |r| r["status"] == "ok" }
          @ok_p = @ok.reject { |r| Hints.implausible?(r) }
          @init_ms = init_ms
          @init_reports = init_reports
          @mixed = MIXED_KEYS.select { |k| @ok.map { |r| mixed_value(r.dig(*k.split("."))) }.compact.uniq.size > 1 }
        end

        # G_ready over `set` (default ok_p). Lines without a plausible start count from load: a
        # rejected start already has the load mark as origin (pre_load is nil), a 0.2.0 bad /proc
        # start is corrected by subtracting pre_load. Not in §3, which only names ok_p; needed so the
        # CPU rules can run on gen2 cells where every start is rejected.
        def ready_p50(set = @ok_p)
          v = set.filter_map { |r| ready_ms(r) }
          v.empty? ? nil : Stats.percentile(v, 50)
        end

        def g_ready?(set = @ok_p) = (ready_p50(set) || 0) >= MIN_READY_MS

        def ready_ms(r)
          t = num(r.dig("phases_ms", "to_ready")) or return nil
          return t unless Hints.implausible?(r)
          pre = num(r.dig("phases_ms", "pre_load"))
          pre ? t - pre : t
        end

        def lambda? = @ok.any? { |r| r.dig("platform", "kind") == "lambda" } || !@init_ms.to_a.empty? || !@init_reports.to_a.empty?

        def gvisor?(set = cpu_set) = set.count { |r| r.dig("limits", "sandbox") == "gvisor" } * 2 >= set.size && !set.empty?

        # --- CPU share (§3 shared definitions)

        # ok lines the CPU rules can read: any ok line with cpu_at_load_ms (rejected starts included),
        # else ok_p lines that are not forked workers (a child's CPU clock restarts at fork, so the
        # whole-process share is wrong there and there is no cpu_at_load_ms to correct it).
        def cpu_set = @cpu_set ||= @ok.select { |r| share(r) }

        # {share:, cpu_ms:, wall_ms:, from_load:} or nil
        def share(r)
          cpu = num(r.dig("proc", "cpu_ms")) or return nil
          at_load = num(r.dig("proc", "cpu_at_load_ms"))
          if at_load
            wall = wall_from_load(r)
            cpu -= at_load
          else
            return nil if r["worker"] || Hints.implausible?(r)
            wall = num(r.dig("phases_ms", "to_first_response"))
          end
          return nil unless wall&.positive? && cpu >= 0
          { share: cpu.to_f / wall, cpu_ms: cpu, wall_ms: wall, from_load: !at_load.nil? }
        end

        # to_first_response - pre_load; with a rejected start pre_load is nil and the marks (load origin) are used
        def wall_from_load(r)
          a = num(r.dig("phases_ms", "to_first_response"))
          b = num(r.dig("phases_ms", "pre_load"))
          return a - b if a && b
          fre = num(r.dig("marks_ms", "first_response_end"))
          loaded = num(r.dig("marks_ms", "loaded"))
          fre && loaded ? fre - loaded : nil
        end

        # median limits.cpu_quota over the set; nil when no line has one (Lambda: no cgroup files, and
        # no nominal memory/1769 estimate, see §9 Q2 revised)
        def quota(set = cpu_set)
          v = set.filter_map { |r| num(r.dig("limits", "cpu_quota")) }
          v.empty? ? nil : Stats.percentile(v, 50).to_f
        end

        # share / min(quota, 1), clamped to 1.0; an unknown quota counts as 1.0
        def busy(share, quota)
          [share / [quota || 1.0, 1.0].min, 1.0].min
        end

        def num(v) = v.is_a?(Numeric) ? v : nil

        private

        # cpu_quota is a ratio of two cgroup values and may differ in the third decimal between lines
        def mixed_value(v) = v.is_a?(Float) ? v.round(1) : v
      end

      @rules = {}

      class << self
        attr_reader :rules

        # Registers a rule. The block gets a Context and returns nil or
        # {level:, n:, evidence:, message:, cannot_see:}.
        def rule(id, &block)
          @rules[id] = block
        end

        def implausible?(rec) = rec["start_rejected"] ? true : Stats.implausible_start?(rec)

        # => [n_ok_plausible, [Hint] ordered by level then id, [mixed keys]]
        def evaluate(records, init_ms: nil, init_reports: nil)
          ctx = Context.new(records, init_ms: init_ms, init_reports: init_reports)
          hints = @rules.filter_map do |id, block|
            h = block.call(ctx) or next
            Hint.new(id: id, level: h[:level], n: h[:n], mixed: !ctx.mixed.empty?, evidence: h[:evidence],
                     message: h[:message], cannot_see: h[:cannot_see] || [])
          end
          [ctx.ok_p.size, hints.sort_by { |h| [LEVELS.index(h.level), h.id] }, ctx.mixed]
        end

        def median(values) = values.empty? ? nil : Stats.percentile(values, 50)

        def sec(ms) = format("%.1f", ms / 1000.0)

        # pre_load can be minutes to days; show it in the largest fitting unit
        def duration(ms)
          s = ms / 1000.0
          if s < 120 then "#{s.round(1)} s"
          elsif s < 7200 then "#{(s / 60).round} min"
          elsif s < 172_800 then "#{(s / 3600).round(1)} h"
          else "#{(s / 86_400).round(1)} d"
          end
        end
      end
    end
  end
end

require_relative "hints/rules"
