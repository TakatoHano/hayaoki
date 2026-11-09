# frozen_string_literal: true

require "time"

module Hayaoki
  module ColdStartReport
    module Stats
      PROACTIVE_IDLE_MS = 1000
      PHASE_ORDER = %w[pre_load pre_bundler bundler_require app_config initialize eager_load to_ready idle first_request to_first_response].freeze
      # Same bound as Insitu::Emitter::MAX_PRE_LOAD_MS (the report does not load insitu). Lines from
      # hayaoki 0.2.0 can carry a bad /proc start (Cloud Run gen1: pre_load of 2 h); their start-based
      # phases are dropped from the distributions, the rest of the line still counts.
      MAX_PRE_LOAD_MS = 600_000
      START_BASED = %w[pre_load to_ready to_first_response].freeze
      ALIASES = { "revision" => "platform.revision", "service" => "platform.service", "init_type" => "platform.init_type",
                  "platform" => "platform.kind", "ruby" => "runtime.ruby", "rails" => "runtime.rails" }.freeze

      module_function

      # nearest-rank percentile (p in 0..100) of a non-empty array
      def percentile(values, p)
        s = values.sort
        s[[(p / 100.0 * s.size).ceil - 1, 0].max]
      end

      def dist(values)
        return nil if values.empty?
        { "n" => values.size, "p50" => rnd(percentile(values, 50)), "p90" => rnd(percentile(values, 90)),
          "p99" => rnd(percentile(values, 99)), "max" => rnd(values.max) }
      end

      def rnd(v) = v.is_a?(Float) ? v.round(1) : v

      def proactive?(rec) = (rec.dig("phases_ms", "idle") || 0) > PROACTIVE_IDLE_MS

      def dig_path(rec, key)
        path = (ALIASES[key] || key).split(".")
        v = rec.dig(*path)
        v = rec.dig("platform", key) if v.nil? && path.size == 1
        v = rec.dig("runtime", key) if v.nil? && path.size == 1
        v.nil? ? nil : v
      rescue TypeError
        nil
      end

      # counts: optional Hash receiving "no_start_at" (rows dropped by --since/--until for lack of a parsable start_at)
      def filter(records, since: nil, until_: nil, exclude_proactive: false, counts: nil)
        records.select do |r|
          next false if exclude_proactive && proactive?(r)
          if since || until_
            t = begin
              Time.iso8601(r["start_at"].to_s)
            rescue ArgumentError
              nil
            end
            unless t
              counts["no_start_at"] += 1 if counts
              next false
            end
            next false if since && t < since
            next false if until_ && t > until_
          end
          true
        end
      end

      # n and status cover every row; the distributions only cover status == "ok" rows
      # (no_request / boot_error / incomplete rows lack the phases and would skew them).
      def summarize(records, platform_init_ms: [])
        s = { "n" => records.size }
        s["status"] = records.map { |r| r["status"] || "unknown" }.tally.sort.to_h
        ok = records.select { |r| r["status"] == "ok" }
        s["n_ok"] = ok.size
        s["proactive"] = ok.count { |r| proactive?(r) }
        s["user_facing"] = ok.size - s["proactive"]
        bad = {}.compare_by_identity
        ok.each { |r| bad[r] = true if implausible_start?(r) }
        s["implausible_start"] = bad.size
        phase = ->(r, k) { START_BASED.include?(k) && bad[r] ? nil : r.dig("phases_ms", k) }
        s["ready_ms"] = dist(ok.filter_map { |r| phase.(r, "to_ready") })
        s["first_response_ms"] = dist(ok.filter_map { |r| phase.(r, "to_first_response") })
        from_load = lambda do |k|
          ok.filter_map do |r|
            a = r.dig("phases_ms", k)
            b = r.dig("phases_ms", "pre_load")
            a - b if a.is_a?(Numeric) && b.is_a?(Numeric)
          end
        end
        s["ready_from_load_ms"] = dist(from_load.("to_ready"))
        s["first_response_from_load_ms"] = dist(from_load.("to_first_response"))
        keys = (PHASE_ORDER + ok.flat_map { |r| (r["phases_ms"] || {}).keys }).uniq
        s["phases_ms"] = keys.to_h { |k| [k, dist(ok.filter_map { |r| phase.(r, k) })] }.compact
        s["eager_top"] = eager(ok)
        s["first_request"] = first_request(ok)
        s["platform_init_ms"] = dist(platform_init_ms)
        s
      end

      # pre_load outside 0..MAX_PRE_LOAD_MS: the process start this line was timed from is not believable
      def implausible_start?(rec)
        v = rec.dig("phases_ms", "pre_load")
        v.is_a?(Numeric) && (v.negative? || v > MAX_PRE_LOAD_MS)
      rescue TypeError
        false
      end

      def eager(records)
        sums = Hash.new { |h, k| h[k] = [] }
        records.each { |r| Array(r["eager_top"]).each { |name, ms| sums[name] << ms if ms } }
        sums.map { |name, v| { "name" => name, "mean_ms" => (v.sum.to_f / v.size).round(1), "lines" => v.size } }
            .sort_by { |h| -h["mean_ms"] }.first(10)
      end

      def first_request(records)
        frs = records.filter_map { |r| r["first_request"] }.select { |f| f.is_a?(Hash) }
        routes = frs.group_by { |f| f["route"] || "(unknown)" }.map do |route, list|
          { "route" => route, "count" => list.size, "p50_ms" => nil }
        end
        # first_request duration lives in phases_ms; pair it with the route
        by_route = Hash.new { |h, k| h[k] = [] }
        records.each do |r|
          f = r["first_request"]
          next unless f.is_a?(Hash)
          ms = r.dig("phases_ms", "first_request")
          by_route[f["route"] || "(unknown)"] << ms if ms
        end
        routes.each { |h| v = by_route[h["route"]]; h["p50_ms"] = v.empty? ? nil : rnd(percentile(v, 50)) }
        groups = Hash.new(0)
        frs.each { |f| Array(f["new_by_group"]).each { |g, c| groups[g] += c.to_i } }
        feats = frs.filter_map { |f| f["new_features"] }
        { "n" => frs.size,
          "top_routes" => routes.sort_by { |h| [-h["count"], h["route"]] }.first(10),
          "new_features_mean" => feats.empty? ? nil : (feats.sum.to_f / feats.size).round(1),
          "new_by_group" => groups.sort_by { |g, c| [-c, g] }.first(10).map { |g, c| { "group" => g, "count" => c } } }
      end

      # { key => [records] }, keys sorted; missing values go under "(none)"
      def group(records, key)
        records.group_by { |r| (v = dig_path(r, key)).nil? ? "(none)" : v.to_s }.sort.to_h
      end
    end
  end
end
