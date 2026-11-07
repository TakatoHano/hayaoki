# frozen_string_literal: true

require "json"
require_relative "../../version"
require_relative "../advisor"

module Hayate
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
          doc = { "schema_version" => SCHEMA_VERSION, "hayate_version" => Hayate::VERSION,
                  "reports" => reports.transform_values(&:to_h) }
          if @suggestions
            doc["suggestions"] = @suggestions.map { |s| s.respond_to?(:to_h) ? s.to_h : s }
            # 非加算の上限 (findings は重複しうる)
            doc["savings_upper_bound_ms"] = Suggestion.savings_upper_bound(@suggestions)
            doc["suggestion_warnings"] = Array(@suggestion_warnings)
          end
          (@pretty ? ::JSON.pretty_generate(doc) : ::JSON.generate(doc)) + "\n"
        end
      end
    end
  end
end
