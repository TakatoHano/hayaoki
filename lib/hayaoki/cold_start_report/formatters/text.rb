# frozen_string_literal: true

module Hayaoki
  module ColdStartReport
    module Formatters
      class Text
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
              out << ""
            end
          else
            summary(out, result["summary"])
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
                   "their pre_load, to_ready and to_first_response are left out below"
          end
          out << ""
          out << "Time to ready / first response (ms)"
          table(out, [["ready", s["ready_ms"]], ["first response", s["first_response_ms"]]])
          out << ""
          out << "Phases (ms)"
          table(out, s["phases_ms"].to_a)
          if s["platform_init_ms"]
            out << ""
            out << "Platform Init Duration (ms, from REPORT lines)"
            table(out, [["init duration", s["platform_init_ms"]]])
          end
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

        def table(out, rows)
          out << Kernel.format("  %-18s %7s %9s %9s %9s %9s", "", "n", "p50", "p90", "p99", "max")
          rows.each do |name, d|
            next out << Kernel.format("  %-18s %7s", name, "-") unless d
            out << Kernel.format("  %-18s %7d %9s %9s %9s %9s", name, d["n"], d["p50"], d["p90"], d["p99"], d["max"])
          end
        end
      end
    end
  end
end
