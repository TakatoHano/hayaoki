# frozen_string_literal: true

require_relative "base"

module Hayate
  module BootReport
    module Rules
      # Rails は active_support.initialize_time_zone で TZInfo を eager_load_namespaces に加え、
      # production の eager_load! で全タイムゾーン (約 600) を読み込む。Linux のコンテナでは 200〜330ms かかる
      # (bench/tzinfo_eager_load.rb)。遅延にすると、使うゾーンだけを初回に読む (1 ゾーン 0.3ms 未満)。
      class TzinfoEagerLoad < Base
        NAME = "TZInfo.eager_load!"
        MIN_MS = 20.0

        def call
          e = Array(get(ctx.report, :eager_namespaces)).find { |x| get(x, :name) == NAME } or return []
          ms = med(get(e, :inclusive_ms))
          return [] unless ms && ms >= MIN_MS
          [suggestion(:medium,
                      title: "#{NAME} loads every time zone at boot (#{round(ms)} ms)",
                      evidence: [{ "namespace" => NAME, "inclusive_ms" => round(ms), "threshold_ms" => MIN_MS }],
                      savings: ms,
                      action: "Rails eager loads all ~600 TZInfo zones in production. To load zones on first use instead, add\n" \
                              "  # config/initializers/tzinfo_lazy.rb\n" \
                              "  Rails.application.config.eager_load_namespaces.delete(TZInfo)\n" \
                              "Each zone is then read when first used (typically well under 1 ms). TZInfo's lazy loading is thread-safe.\n" \
                              "Trade-off: with a forking server (Puma workers + preload_app!), zones are no longer loaded before fork, " \
                              "so they are not shared copy-on-write. Most useful for serverless and short-lived processes.")]
        end
      end
    end
  end
end
