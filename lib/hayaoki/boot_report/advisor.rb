# frozen_string_literal: true

require_relative "rules/base"

module Hayaoki
  module BootReport
    # 改善候補 1 件。evidence は String キーの Hash の配列。
    Suggestion = Struct.new(:rule, :confidence, :title, :evidence, :estimated_savings_ms, :action, :id, :overlaps, keyword_init: true) do
      # 各 finding の節約見込みは重複しうるので足し算では出さず、上限 (単純和) として扱う。
      def self.savings_upper_bound(list)
        v = list.filter_map(&:estimated_savings_ms)
        v.empty? ? nil : v.sum.round(1)
      end

      def to_h
        { "id" => id, "overlaps" => Array(overlaps), "rule" => rule.to_s, "confidence" => confidence.to_s, "title" => title, "evidence" => evidence,
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
        require_relative "rules/tzinfo_eager_load"
        require_relative "rules/devise_reload_routes"
        require_relative "rules/controller_action_methods"
        [Rules::DevGemsInProduction, Rules::BootsnapIneffective, Rules::HeavyAppInitializer,
         Rules::UnusedHeavyGem, Rules::EagerLoadTradeoff, Rules::TzinfoEagerLoad,
         Rules::DeviseReloadRoutes, Rules::ControllerActionMethods]
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
        sorted = out.each_with_index.sort_by { |s, i| [CONFIDENCE_ORDER.index(s.confidence) || 99, -(s.estimated_savings_ms || 0), i] }.map(&:first)
        mark_overlaps(sorted)
      end

      GEM_EVIDENCE_KEY = { dev_gems_in_production: "name", unused_heavy_gem: "gem" }.freeze
      GEM_RULES = GEM_EVIDENCE_KEY.keys.freeze

      # id を振り、節約見込みが重なりうる finding を overlaps に載せる。
      #  - 同じ gem を別ルールが指している
      #  - app initializer の inclusive 時間には gem の require が含まれうるので、gem 系の finding と重なる
      #  - TZInfo.eager_load! などの時間は eager_load フェーズに含まれる
      def mark_overlaps(list)
        seen = Hash.new(0)
        list.each do |s|
          seen[s.rule] += 1
          s.id = seen[s.rule] == 1 ? s.rule.to_s : "#{s.rule}##{seen[s.rule]}"
        end
        gems = {}.compare_by_identity
        list.each { |s| gems[s] = gem_subjects(s) }
        list.each do |s|
          s.overlaps = list.filter_map do |o|
            next if o.equal?(s)
            o.id if (gems[s] & gems[o]).any? || initializer_vs_gem?(s, o) || eager_phase_pair?(s, o)
          end
        end
        list
      end

      # eager_load フェーズの中の処理を指す finding は、eager_load_tradeoff と節約見込みが重なる
      EAGER_PHASE_RULES = %i[tzinfo_eager_load controller_action_methods].freeze

      def eager_phase_pair?(a, b)
        pair = [a.rule, b.rule]
        pair.include?(:eager_load_tradeoff) && pair.any? { |r| EAGER_PHASE_RULES.include?(r) }
      end

      def initializer_vs_gem?(a, b)
        pair = [a.rule, b.rule]
        pair.include?(:heavy_app_initializer) && pair.any? { |r| GEM_RULES.include?(r) }
      end

      def gem_subjects(s)
        key = GEM_EVIDENCE_KEY[s.rule]
        return [] unless key
        Array(s.evidence).filter_map { |e| e[key] if e.is_a?(Hash) }
      end
    end
  end
end
