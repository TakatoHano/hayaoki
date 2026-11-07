# frozen_string_literal: true

require_relative "base"

module Hayate
  module BootReport
    module Rules
      # Devise は before_eager_load で app.reload_routes! を呼ぶ (Devise.reload_routes = true が初期値)。
      # production では set_routes_reloader_hook でもルーティングを読むので、起動中に 2 回読むことになる。
      # Mastodon で 194ms 短くなった (bench/boot_variants.rb)。Devise 5.0 からは Devise.mappings を参照したときに
      # 必要ならルーティングを読むので、false にしても mappings は使える。4.x にはこの処理が無い。
      class DeviseReloadRoutes < Base
        SOURCE = "/lib/devise/rails.rb"
        MIN_MS = 50.0

        def call
          hook = Array(get(ctx.report, :on_loads)).find do |h|
            get(h, :name).to_s == "before_eager_load" && get(h, :source).to_s.include?(SOURCE)
          end or return []
          ms = med(get(hook, :inclusive_ms))
          return [] unless ms && ms >= MIN_MS
          version = gem_versions["devise"]
          modern = version && Gem::Version.new(version) >= Gem::Version.new("5.0.0.rc")
          caveat = if modern
                     "Devise #{version} loads the routes on demand when Devise.mappings is first used, so this is safe " \
                       "unless your own code reads Devise.mappings during eager loading."
                   else
                     "Devise #{version || "(version unknown)"} builds Devise.mappings only when the routes are loaded. " \
                       "Routes are still loaded later in boot (set_routes_reloader_hook), but code that reads " \
                       "Devise.mappings during eager loading would see none. Devise 5.0+ removes this risk."
                   end
          [suggestion(modern ? :medium : :low,
                      title: "Devise reloads the routes before eager loading (#{round(ms)} ms); they are loaded again later in boot",
                      evidence: [{ "hook" => "before_eager_load", "source" => "devise/rails.rb", "inclusive_ms" => round(ms),
                                   "devise" => version, "threshold_ms" => MIN_MS }],
                      savings: ms,
                      action: "In config/initializers/devise.rb:\n" \
                              "  config.reload_routes = false\n" + caveat)]
        end
      end
    end
  end
end
