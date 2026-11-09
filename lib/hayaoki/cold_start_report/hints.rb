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
      MIXED_KEYS = %w[platform.revision platform.memory_mb runtime.bootsnap].freeze

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
          @mixed = MIXED_KEYS.select { |k| @ok.map { |r| r.dig(*k.split(".")) }.compact.uniq.size > 1 }
        end

        def ready_p50
          v = @ok_p.filter_map { |r| num(r.dig("phases_ms", "to_ready")) }
          v.empty? ? nil : Stats.percentile(v, 50)
        end

        def g_ready? = (ready_p50 || 0) >= MIN_READY_MS

        def lambda? = @ok.any? { |r| r.dig("platform", "kind") == "lambda" } || !@init_ms.to_a.empty? || !@init_reports.to_a.empty?

        def num(v) = v.is_a?(Numeric) ? v : nil
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
