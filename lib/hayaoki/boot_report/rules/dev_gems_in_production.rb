# frozen_string_literal: true

require_relative "base"

module Hayaoki
  module BootReport
    module Rules
      # 開発・テスト用の既知の gem が、計測した環境 (既定は production) で読み込まれている。
      class DevGemsInProduction < Base
        # 完全一致
        DEV_GEMS = %w[
          pry byebug debug rubocop web-console listen spring rspec factory_bot factory_bot_rails faker
          better_errors binding_of_caller bullet annotate annotate_models brakeman guard minitest-reporters
          capybara selenium-webdriver webdrivers rails-controller-testing shoulda-matchers simplecov
          database_cleaner database_cleaner-active_record rack-mini-profiler letter_opener derailed_benchmarks
          rubocop-ast
        ].freeze
        # 前方一致 (pry-rails, rubocop-rails, rspec-core, spring-watcher-listen ...)
        DEV_GEM_PREFIXES = %w[pry- rubocop- rspec- spring- factory_bot_ capybara- guard- web-console- debug_].freeze
        # 開発・テスト以外の環境ではこの rule は対象外
        NON_PRODUCTION_ENVS = %w[development test].freeze

        def self.dev_gem?(name)
          DEV_GEMS.include?(name) || DEV_GEM_PREFIXES.any? { |p| name.start_with?(p) }
        end

        # テスト用データ生成系は本番で読み込まれると実害 (メモリ・起動時間) が大きいので medium に引き上げる
        MEDIUM_GEMS = %w[faker factory_bot factory_bot_rails].freeze
        DEV_GROUPS = %w[development test].freeze

        def call
          return [] if NON_PRODUCTION_ENVS.include?(ctx.env)
          entries = gemfile_entries
          tiers = Hash.new { |h, k| h[k] = [] }
          ctx.gems.each do |g|
            name = get(g, :name).to_s
            next unless get(g, :category).to_s == "gem" && self.class.dev_gem?(name)
            entry = entries && entries[name]
            # development/test の group だけに属する gem は本番では読み込まれない
            next if entry && !entry.groups.empty? && entry.groups.all? { DEV_GROUPS.include?(_1) }
            ms = med(get(g, :self_ms))
            row = { "name" => name, "self_ms" => round(ms || 0.0),
                    "gemfile" => entry ? (entry.groups.empty? ? "direct, no group" : "direct, groups: #{entry.groups.join(",")}") : (entries ? "transitive" : "unknown (no Gemfile)") }
            tiers[tier(name, entry)] << row
          end
          %i[high medium low].filter_map { |t| tiers.key?(t) && build(t, tiers[t]) }
        end

        private

        # Gemfile に直接書かれ group 無し (= production で読み込まれる) なら high、
        # 間接依存や Gemfile 不明は確認できないので low。
        def tier(name, entry)
          return :low unless entry
          MEDIUM_GEMS.include?(name) ? :medium : :high
        end

        def build(tier, found)
          total = found.sum { |f| f["self_ms"] }
          names = found.map { |f| f["name"] }
          env = ctx.env.empty? ? "the measured environment" : ctx.env
          title = if tier == :low
            "Development/test gems may be loaded in #{env} via other dependencies (#{names.first(3).join(", ")}#{names.size > 3 ? ", ..." : ""})"
          else
            "Development/test gems are loaded in #{env} (#{names.first(3).join(", ")}#{names.size > 3 ? ", ..." : ""})"
          end
          action = if tier == :low
            "These were not found as direct Gemfile entries (transitive dependency or Gemfile not found). " \
            "Check which gem depends on them (`bundle viz` / `bundle why`) before acting."
          else
            "Move them to the development/test groups in the Gemfile, e.g.:\n" \
            "  group :development, :test do\n    #{names.first(3).map { |n| %(gem "#{n}") }.join("\n    ")}\n  end\n" \
            "Check first that nothing in production code depends on them."
          end
          suggestion(tier, title: title, evidence: found.sort_by { |f| -f["self_ms"] }, savings: total, action: action)
        end
      end
    end
  end
end
