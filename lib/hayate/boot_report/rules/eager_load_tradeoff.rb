# frozen_string_literal: true

require_relative "base"

module Hayate
  module BootReport
    module Rules
      # eager_load の割合が大きいときの判断材料 (情報のみ)。
      class EagerLoadTradeoff < Base
        MIN_RATIO = 0.15

        def call
          eager = ctx.phase_ms("eager_load")
          total = ctx.phase_ms("boot") || ctx.phase_ms("total")
          return [] unless eager && total && total.positive?
          ratio = eager / total
          return [] if ratio < MIN_RATIO
          [suggestion(:info,
                      title: "eager_load accounts for #{(ratio * 100).round(1)}% of boot time",
                      evidence: [{ "eager_load_ms" => round(eager), "boot_ms" => round(total), "ratio" => ratio.round(3),
                                   "threshold" => MIN_RATIO }],
                      savings: eager,
                      action: "For serverless or short-lived processes where boot latency matters, you could consider " \
                              "config.eager_load = false: boot gets faster, but classes are then loaded on first use, " \
                              "so the first requests may be slower and thread-safety/CoW benefits of eager loading are lost. " \
                              "For long-running servers, keeping eager_load enabled is usually preferable. " \
                              "The estimated saving moves work to the first request; it is not a net saving.")]
        end
      end
    end
  end
end
