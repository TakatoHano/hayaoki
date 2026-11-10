# frozen_string_literal: true

require_relative "../hints"

module Hayaoki
  module ColdStartReport
    module Formatters
      class Text
        CANNOT_SEE = { "aws_lwa_async_init" => "AWS_LWA_ASYNC_INIT", "image_pull" => "image pull and layer caching",
                       "cpu_allocation" => "Cloud Run CPU allocation", "ruby_gc_env" => "RUBY_GC_* settings",
                       "startup_cpu_boost" => "Cloud Run startup CPU boost",
                       "execution_environment" => "Cloud Run execution environment (gen1/gen2)" }.freeze

        def format(result)
          out = ["hayaoki cold-start-report"]
          inp = result["input"]
          out << "  #{inp["lines"]} cold start line(s); skipped #{inp["skipped_other"]} other, #{inp["skipped_invalid"]} invalid" \
                 "#{", filtered out #{inp["filtered"]}" if inp["filtered"].to_i > 0}" \
                 "#{" (#{inp["filtered_no_start_at"]} without start_at)" if inp["filtered_no_start_at"].to_i > 0}" \
                 "#{", #{inp["skipped_duplicate"]} duplicate" if inp["skipped_duplicate"].to_i > 0}"
          out << "  group by: #{result["group_by"]}" if result["group_by"]
          out << ""
          if result["groups"]
            result["groups"].each do |key, s|
              out << "== #{result["group_by"]}: #{key} =="
              summary(out, s)
              hints(out, s)
              out << ""
            end
            init_reports(out, result["platform_init_reports"])
          else
            summary(out, result["summary"])
            hints(out, result["summary"])
          end
          sums = result["groups"] ? result["groups"].values : [result["summary"]]
          if sums.any? { |s| s["hints"]&.any? }
            out << "" unless out.last == ""
            out << "These hints do not cover how often users hit a cold start (min instances)."
          end
          out.join("\n").rstrip + "\n"
        end

        private

        def summary(out, s)
          out << "n: #{s["n"]}  (#{s["status"].map { |k, v| "#{k}=#{v}" }.join(" ")})"
          out << "ok starts: user-facing #{s["user_facing"]}, proactive (idle > #{Stats::PROACTIVE_IDLE_MS}ms) #{s["proactive"]}  (distributions below use status=ok only)"
          return if s["n_ok"].zero?
          if s["implausible_start"].to_i > 0
            out << "warning: #{s["implausible_start"]} line(s) with pre_load outside 0..#{Stats::MAX_PRE_LOAD_MS}ms (bad /proc process start); " \
                   "their pre_load, to_ready and to_first_response are left out below; the \"(from load)\" rows include them"
          end
          out << ""
          out << "Time to ready / first response (ms)"
          table(out, [["ready", s["ready_ms"]], ["first response", s["first_response_ms"]],
                      ["ready (from load)", s["ready_from_load_ms"]], ["first response (from load)", s["first_response_from_load_ms"]]])
          out << ""
          out << "Phases (ms)"
          table(out, s["phases_ms"].to_a)
          if s["platform_init_ms"]
            out << ""
            out << "Platform Init Duration (ms, from REPORT lines)"
            table(out, [["init duration", s["platform_init_ms"]]])
          end
          init_reports(out, s["platform_init_reports"])
          unless s["eager_top"].empty?
            out << ""
            out << "Eager load top (mean ms)"
            s["eager_top"].each { |h| out << Kernel.format("  %-28s %8.1f  (%d lines)", h["name"], h["mean_ms"], h["lines"]) }
          end
          fr = s["first_request"]
          return if fr["n"].zero?
          out << ""
          out << "First request (#{fr["n"]} line(s)#{", mean new features #{fr["new_features_mean"]}" if fr["new_features_mean"]})"
          fr["top_routes"].each { |h| out << Kernel.format("  %-32s x%-4d p50 %s", h["route"], h["count"], h["p50_ms"] ? "#{h["p50_ms"]}ms" : "-") }
          unless fr["new_by_group"].empty?
            out << "  lazy-loaded features by group:"
            fr["new_by_group"].each { |h| out << Kernel.format("    %-28s %6d", h["group"], h["count"]) }
          end
        end

        def init_reports(out, list)
          return unless list
          out << ""
          out << "Platform INIT_REPORT lines: #{list.map { |h| "#{h["phase"]}/#{h["status"]} x#{h["count"]}" }.join(", ")}"
        end

        def hints(out, s)
          return unless s.key?("hints")
          list = s["hints"]
          n = s["hints_n"]
          few = "hints need at least #{Hints::MIN_N} ok cold starts with a plausible start (have #{n})"
          out << ""
          if list.empty?
            out << "Hints: #{n < Hints::MIN_N ? few : "none (n=#{n})"}"
            return
          end
          out << "Hints (likely causes outside app code; based on #{s["n_ok"]} ok cold starts, #{n} with a plausible start)"
          list.each { |h| out << Kernel.format("  %-9s %-23s %s", h["level"], h["id"], h["message"]) }
          out << "            Start-based hints (bootsnap, GC, Lambda Init) need at least #{Hints::MIN_N} ok cold starts with a plausible start (have #{n}); skipped." if n < Hints::MIN_N
          if (keys = s["hints_mixed"])
            names = keys.map { _1.split(".").last }
            out << "            Lines come from different configurations (#{names.join(", ")}); try --group-by #{names.first}."
          end
          seen = list.flat_map { |h| h["cannot_see"] }.uniq
          out << "            Cannot see: #{seen.map { |k| CANNOT_SEE[k] || k }.join(", ")}" unless seen.empty?
        end

        def table(out, rows)
          out << Kernel.format("  %-27s %7s %9s %9s %9s %9s", "", "n", "p50", "p90", "p99", "max")
          rows.each do |name, d|
            next out << Kernel.format("  %-27s %7s", name, "-") unless d
            out << Kernel.format("  %-27s %7d %9s %9s %9s %9s", name, d["n"], d["p50"], d["p90"], d["p99"], d["max"])
          end
        end
      end
    end
  end
end
