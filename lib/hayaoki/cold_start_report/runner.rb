# frozen_string_literal: true

require_relative "reader"
require_relative "stats"
require_relative "hints"

module Hayaoki
  module ColdStartReport
    # Builds the result hash from input texts. opts: group_by, since, until_, exclude_proactive, hints.
    def self.build(texts, group_by: nil, since: nil, until_: nil, exclude_proactive: false, hints: true)
      reader = Reader.new
      texts.each { |t| reader.read(t) }
      counts = Hash.new(0)
      records = Stats.filter(reader.records, since: since, until_: until_, exclude_proactive: exclude_proactive, counts: counts)
      init_reports = reader.init_report_counts
      result = {
        "input" => { "lines" => records.size, "skipped_other" => reader.skipped_other, "skipped_invalid" => reader.skipped_invalid,
                     "filtered" => reader.records.size - records.size,
                     "filtered_no_start_at" => counts["no_start_at"], "skipped_duplicate" => reader.skipped_duplicate },
        "group_by" => group_by
      }
      if group_by
        groups = Stats.group(records, group_by)
        # Platform lines carry no revision or memory size; tie them to a group only when one group has Lambda lines.
        lambda_keys = groups.select { |_, rs| rs.any? { |r| r.dig("platform", "kind") == "lambda" } }.keys
        result["groups"] = groups.to_h do |key, rs|
          s = Stats.summarize(rs)
          if hints
            own = lambda_keys == [key]
            add_hints(s, rs, own ? reader.platform_init_ms : nil, own ? init_reports : nil)
          end
          [key, s]
        end
        result["platform_init_ms"] = Stats.dist(reader.platform_init_ms)
        result["platform_init_reports"] = init_reports
      else
        s = Stats.summarize(records, platform_init_ms: reader.platform_init_ms)
        s["platform_init_reports"] = init_reports
        add_hints(s, records, reader.platform_init_ms, init_reports) if hints
        result["summary"] = s
      end
      result
    end

    def self.add_hints(summary, records, init_ms, init_reports)
      n, list, mixed = Hints.evaluate(records, init_ms: init_ms, init_reports: init_reports)
      summary["hints_n"] = n
      summary["hints_mixed"] = mixed unless mixed.empty?
      summary["hints"] = list.map(&:to_h)
    end
  end
end
