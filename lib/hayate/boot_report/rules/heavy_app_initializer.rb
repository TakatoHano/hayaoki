# frozen_string_literal: true

require_relative "base"

module Hayate
  module BootReport
    module Rules
      # アプリ自身の initializer (config/initializers 配下など) が重い。
      class HeavyAppInitializer < Base
        def call
          items = candidates.select { |i| i["inclusive_ms"] > ctx.initializer_threshold_ms }
          return [] if items.empty?
          items.sort_by! { |i| -i["inclusive_ms"] }
          [suggestion(:medium,
                      title: "#{items.size} app initializer(s) take more than #{fmt(ctx.initializer_threshold_ms)} ms; " \
                             "they may be deferrable (slowest: #{items.first["name"]})",
                      evidence: items,
                      savings: items.sum { |i| i["inclusive_ms"] },
                      action: "Consider (the time may include gem requires counted elsewhere):\n" \
                              "  - run it later: Rails.application.config.after_initialize { ... }\n" \
                              "  - require heavy libraries lazily, inside the code that uses them\n" \
                              "  - register it with ActiveSupport.on_load(:active_record) { ... } so it runs only when needed\n" \
                              "Savings are an upper bound: deferred work still runs, just later.")]
        end

        private

        def candidates
          by_name = {}
          # 切り詰め前の app_initializer_times があればそれを使う (無ければ表示用の上位 N 件)
          full = get(ctx.report, :app_initializer_times)
          inits = full ? get(full, :initializers) : get(ctx.report, :initializers)
          files = full ? get(full, :files) : get(ctx.report, :files)
          Array(inits).each do |i|
            next unless get(i, :category).to_s == "app"
            ms = med(get(i, :inclusive_ms)) or next
            name = [get(i, :name), get(i, :context)].compact.join(" ")
            add(by_name, name, ms, "initializer")
          end
          Array(files).each do |f|
            path = get(f, :path).to_s
            next unless get(f, :category).to_s == "app" && path.include?("/config/initializers/")
            ms = med(get(f, :inclusive_ms)) or next
            add(by_name, path.sub(%r{\A.*?/(config/initializers/)}, '\1'), ms, "file")
          end
          by_name.values
        end

        def add(h, name, ms, kind)
          cur = h[name]
          return if cur && cur["inclusive_ms"] >= ms
          h[name] = { "name" => name, "kind" => kind, "inclusive_ms" => round(ms) }
        end

        def fmt(x) = x == x.to_i ? x.to_i.to_s : x.to_s
      end
    end
  end
end
