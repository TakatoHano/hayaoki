# frozen_string_literal: true

require_relative "reader"
require_relative "stats"

module Hayaoki
  module ColdStartReport
    # Builds the result hash from input texts. opts: group_by, since, until_, exclude_proactive.
    def self.build(texts, group_by: nil, since: nil, until_: nil, exclude_proactive: false)
      reader = Reader.new
      texts.each { |t| reader.read(t) }
      counts = Hash.new(0)
      records = Stats.filter(reader.records, since: since, until_: until_, exclude_proactive: exclude_proactive, counts: counts)
      result = {
        "input" => { "lines" => records.size, "skipped_other" => reader.skipped_other, "skipped_invalid" => reader.skipped_invalid,
                     "filtered" => reader.records.size - records.size,
                     "filtered_no_start_at" => counts["no_start_at"], "skipped_duplicate" => reader.skipped_duplicate },
        "group_by" => group_by
      }
      if group_by
        result["groups"] = Stats.group(records, group_by).transform_values { |rs| Stats.summarize(rs) }
        result["platform_init_ms"] = Stats.dist(reader.platform_init_ms)
      else
        result["summary"] = Stats.summarize(records, platform_init_ms: reader.platform_init_ms)
      end
      result
    end
  end
end
