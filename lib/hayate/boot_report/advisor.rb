# frozen_string_literal: true

require_relative "rules/base"

module Hayate
  module BootReport
    # 改善候補 1 件。evidence は String キーの Hash の配列。
    Suggestion = Struct.new(:rule, :confidence, :title, :evidence, :estimated_savings_ms, :action, keyword_init: true) do
      def to_h
        { "rule" => rule.to_s, "confidence" => confidence.to_s, "title" => title, "evidence" => evidence,
          "estimated_savings_ms" => estimated_savings_ms, "action" => action }
      end
    end

    # Report (と RunResult) から Suggestion を作る。ルールの例外は警告にして続行する。
    class Advisor
      CONFIDENCE_ORDER = %i[high medium low info].freeze
      DEFAULT_INITIALIZER_THRESHOLD_MS = 50
      DEFAULT_GEM_THRESHOLD_MS = 30

      attr_reader :warnings

      def self.rules
        require_relative "rules/dev_gems_in_production"
        require_relative "rules/bootsnap_ineffective"
        require_relative "rules/heavy_app_initializer"
        require_relative "rules/unused_heavy_gem"
        require_relative "rules/eager_load_tradeoff"
        [Rules::DevGemsInProduction, Rules::BootsnapIneffective, Rules::HeavyAppInitializer,
         Rules::UnusedHeavyGem, Rules::EagerLoadTradeoff]
      end

      def initialize(report, app_dir:, result: nil, initializer_threshold_ms: DEFAULT_INITIALIZER_THRESHOLD_MS,
                     gem_threshold_ms: DEFAULT_GEM_THRESHOLD_MS, rules: self.class.rules)
        @ctx = Context.new(report: report, app_dir: app_dir, result: result,
                           initializer_threshold_ms: initializer_threshold_ms, gem_threshold_ms: gem_threshold_ms)
        @rules = rules
        @warnings = []
      end

      def suggestions
        @suggestions ||= run
      end

      private

      def run
        out = @rules.flat_map do |klass|
          Array(klass.new(@ctx).call)
        rescue StandardError, NotImplementedError => e
          id = klass.respond_to?(:rule_id) ? klass.rule_id : klass.to_s
          @warnings << "suggestion rule #{id} failed: #{e.class}: #{e.message}"[0, 300]
          []
        end
        out.each_with_index.sort_by { |s, i| [CONFIDENCE_ORDER.index(s.confidence) || 99, -(s.estimated_savings_ms || 0), i] }.map(&:first)
      end
    end
  end
end
