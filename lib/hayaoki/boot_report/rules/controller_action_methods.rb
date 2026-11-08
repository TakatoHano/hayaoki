# frozen_string_literal: true

require_relative "base"

module Hayaoki
  module BootReport
    module Rules
      # AbstractController.eager_load! は全コントローラの action_methods を起動時に計算する。
      # 遅延にすると、各コントローラの最初のリクエストで自分の分だけ計算する
      # (Mastodon: 起動 -201ms、336 コントローラ合計 217ms = 1 個あたり約 0.65ms)。
      class ControllerActionMethods < Base
        NAME = "AbstractController.eager_load!"
        MIN_MS = 100.0

        def call
          e = Array(get(ctx.report, :eager_namespaces)).find { |x| get(x, :name) == NAME } or return []
          ms = med(get(e, :inclusive_ms))
          return [] unless ms && ms >= MIN_MS
          [suggestion(:low,
                      title: "#{NAME} computes action_methods for every controller at boot (#{round(ms)} ms)",
                      evidence: [{ "namespace" => NAME, "inclusive_ms" => round(ms), "threshold_ms" => MIN_MS }],
                      savings: ms,
                      action: "To compute each controller's action_methods on its first request instead, add\n" \
                              "  # config/initializers/lazy_action_methods.rb\n" \
                              "  Rails.application.config.eager_load_namespaces.delete(AbstractController)\n" \
                              "The work moves to requests, but each request pays only for its own controller " \
                              "(the total divided by the number of controllers). Useful for serverless and short-lived " \
                              "processes; for long-running servers, keeping it is usually better.")]
        end
      end
    end
  end
end
