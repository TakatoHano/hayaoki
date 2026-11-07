# frozen_string_literal: true

require_relative "base"

module Hayate
  module BootReport
    module Rules
      # bootsnap が無い / 効いていない可能性。
      class BootsnapIneffective < Base
        MIN_DIFF_RATIO = 0.05 # cold と warm の差がこれ未満なら効いていないとみなす
        CACHE_WARNING = /BOOTSNAP_CACHE_DIR was not used/

        def call
          loaded = ctx.gems.any? { |g| get(g, :name).to_s == "bootsnap" }
          return [missing(loaded_in_gemfile?)] unless loaded
          out = []
          out << small_diff
          out << cache_unused
          out.compact
        end

        private

        def loaded_in_gemfile? = !!(gemfile.to_s =~ /^\s*gem\s+["']bootsnap["']/)

        def missing(in_gemfile)
          if in_gemfile
            suggestion(:high,
                       title: "bootsnap is in the Gemfile but does not seem to be loaded at boot",
                       evidence: [{ "bootsnap_in_gemfile" => true, "loaded_at_boot" => false }],
                       action: "Check that config/boot.rb contains `require \"bootsnap/setup\"` (after bundler/setup), " \
                               "or remove `require: false` handling that skips it.")
          else
            suggestion(:high,
                       title: "bootsnap was not loaded; adding it can speed up boot",
                       evidence: [{ "bootsnap_loaded" => false }],
                       action: "Add to the Gemfile: gem \"bootsnap\", require: false\n" \
                               "and to config/boot.rb (after `require \"bundler/setup\"`): require \"bootsnap/setup\"")
          end
        end

        def small_diff
          warm = boot_ms(:warm)
          cold = boot_ms(:cold)
          return nil unless warm && cold && cold.positive?
          diff = cold - warm
          return nil unless diff / cold < MIN_DIFF_RATIO
          suggestion(:high,
                     title: "bootsnap's warm cache shows little benefit over a cold cache (#{(diff / cold * 100).round(1)}%)",
                     evidence: [{ "cold_ms" => round(cold), "warm_ms" => round(warm), "diff_ms" => round(diff),
                                  "threshold_pct" => MIN_DIFF_RATIO * 100 }],
                     action: "Bootsnap may not be configured as expected. Check that Bootsnap.setup (or bootsnap/setup) " \
                             "runs before the app loads, that cache_dir is writable and persisted between boots, " \
                             "and that load_path_cache / compile_cache are enabled.")
        end

        def cache_unused
          hit = ctx.warnings.grep(CACHE_WARNING)
          return nil if hit.empty?
          suggestion(:high,
                     title: "bootsnap's cache directory stayed empty during measurement",
                     evidence: hit.map { |w| { "warning" => w } },
                     action: "The app may call Bootsnap.setup with its own cache_dir, or bootsnap is not active. " \
                             "Make sure the cache is actually written (default tmp/cache/bootsnap) and kept between deploys/boots.")
        end

        # 条件ごとの boot 時間 (ms, 中央値)。payload の boot_end_us / exit_us から求める。
        def boot_ms(cond)
          list = payloads(cond)
          vals = list.filter_map do |p|
            us = get(p, :boot_end_us) || get(p, :exit_us)
            us && us / 1000.0
          end
          return nil if vals.empty?
          s = vals.sort
          n = s.size
          n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
        end

        def payloads(cond)
          pl = get(ctx.result, :payloads)
          return [] unless pl.is_a?(Hash)
          Array(pl[cond] || pl[cond.to_s]).select { |p| get(p, :status).to_s == "ok" }
        end
      end
    end
  end
end
