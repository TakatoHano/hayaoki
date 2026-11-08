# frozen_string_literal: true

require "json"
require_relative "../../version"
require_relative "../advisor"

module Hayaoki
  module BootReport
    module Formatters
      class Json
        SCHEMA_VERSION = 1

        def initialize(pretty: true)
          @pretty = pretty
        end

        attr_accessor :suggestions, :suggestion_warnings

        def with_suggestions(list, warnings = [])
          @suggestions = list
          @suggestion_warnings = warnings
          self
        end

        # reports: { "warm" => Report, ... } または Report 単体
        def format(reports)
          reports = { reports.condition.to_s => reports } unless reports.is_a?(Hash)
          reports = reports.transform_values { |r| scrub(r.to_h) }
          reports = reports.transform_values { |r| scrub(r.to_h) }
          doc = { "schema_version" => SCHEMA_VERSION, "hayaoki_version" => Hayaoki::VERSION,
                  "reports" => reports }
          if @suggestions
            doc["suggestions"] = @suggestions.map { |s| s.respond_to?(:to_h) ? s.to_h : s }
            # 非加算の上限 (findings は重複しうる)
            doc["savings_upper_bound_ms"] = Suggestion.savings_upper_bound(@suggestions)
            doc["suggestion_warnings"] = Array(@suggestion_warnings)
          end
          (@pretty ? ::JSON.pretty_generate(doc) : ::JSON.generate(doc)) + "\n"
        end

        private

        # 失敗 run の stderr_tail は秘密を含みうるので出力しない (message / exit_status / error_class は残す)
        def scrub(h)
          meta = h["meta"]
          return h unless meta.is_a?(Hash) && meta["failed_runs"].is_a?(Array)
          h.merge("meta" => meta.merge("failed_runs" => meta["failed_runs"].map { |f| f.reject { |k, _| k == "stderr_tail" } }))
        end
      end
    end
  end
end
