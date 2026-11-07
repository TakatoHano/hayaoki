# frozen_string_literal: true

require_relative "base"

module Hayate
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

        def call
          return [] if NON_PRODUCTION_ENVS.include?(ctx.env)
          found = ctx.gems.filter_map do |g|
            name = get(g, :name).to_s
            next unless get(g, :category).to_s == "gem" && self.class.dev_gem?(name)
            ms = med(get(g, :self_ms))
            { "name" => name, "self_ms" => round(ms || 0.0) }
          end
          return [] if found.empty?
          total = found.sum { |f| f["self_ms"] }
          names = found.map { |f| f["name"] }
          [suggestion(:high,
                      title: "Development/test gems appear to be loaded in #{ctx.env.empty? ? "the measured environment" : ctx.env} (#{names.first(3).join(", ")}#{names.size > 3 ? ", ..." : ""})",
                      evidence: found.sort_by { |f| -f["self_ms"] },
                      savings: total,
                      action: "Move them to the development/test groups in the Gemfile, e.g.:\n" \
                              "  group :development, :test do\n    #{names.first(3).map { |n| %(gem "#{n}") }.join("\n    ")}\n  end\n" \
                              "Check first that nothing in production code depends on them.")]
        end
      end
    end
  end
end
