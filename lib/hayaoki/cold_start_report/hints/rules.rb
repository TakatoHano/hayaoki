# frozen_string_literal: true

module Hayaoki
  module ColdStartReport
    module Hints
      LAMBDA_NEAR_MS = 7000 # Q7: p90 of Init / to_ready at or above this is "near" the 10 s limit
      GC_SHARE = 0.20

      rule("bootsnap_off") do |c|
        set = c.ok_p.reject { |r| r.dig("runtime", "bootsnap").nil? }
        next if set.size < MIN_N
        k = set.count { |r| r.dig("runtime", "bootsnap") == false }
        next if k * 2 < set.size
        { level: "likely", n: set.size, evidence: { "off" => k },
          message: "bootsnap was not loaded in #{k} of #{set.size} cold starts. With bootsnap and a cache built into the image, " \
                   "boot likely skips load-path scans and recompiles. Measure the gain with `hayaoki boot-report`." }
      end

      # bootsnap_cache is null when bootsnap loaded before hayaoki; those lines are left out.
      rule("bootsnap_cache_cold") do |c|
        set = c.ok_p.select { |r| r.dig("runtime", "bootsnap") == true && !r.dig("runtime", "bootsnap_cache").nil? }
        next if set.size < MIN_N
        k = set.count { |r| r.dig("runtime", "bootsnap_cache") == false }
        next if k * 2 < set.size
        msg = "bootsnap is on, but its cache directory did not exist at boot in #{k} of #{set.size} cold starts, " \
              "so each cold start likely rebuilds it. Precompile it in the image (`bootsnap precompile`) and check " \
              "that the cache dir at runtime is the one built into the image."
        msg += " On Lambda the image filesystem is read-only; a cache written at runtime goes to /tmp and is lost with the environment." if c.lambda?
        { level: "likely", n: set.size, evidence: { "cache_missing" => k }, message: msg }
      end

      rule("gc_pressure") do |c|
        set = c.ok_p.select { |r| (cpu = r.dig("proc", "cpu_ms")).is_a?(Numeric) && cpu.positive? && r.dig("proc", "gc_time_ms").is_a?(Numeric) }
        next if set.size < MIN_N || !c.g_ready?
        share = median(set.map { |r| r.dig("proc", "gc_time_ms").to_f / r.dig("proc", "cpu_ms") })
        next if share < GC_SHARE
        gc_ms = median(set.map { |r| r.dig("proc", "gc_time_ms") })
        cpu_ms = median(set.map { |r| r.dig("proc", "cpu_ms") })
        counts = set.filter_map { |r| r.dig("proc", "gc_count") }.grep(Numeric)
        gc_count = median(counts)
        pct = (share * 100).round
        { level: "possible", n: set.size,
          evidence: { "gc_share_p50" => share.round(2), "gc_ms_p50" => gc_ms, "cpu_ms_p50" => cpu_ms, "gc_count_p50" => gc_count },
          message: "GC took #{pct}% of boot CPU (median #{gc_ms} ms of #{cpu_ms} ms#{", #{gc_count} GCs" if gc_count}). " \
                   "Heap tuning (`RUBY_GC_HEAP_INIT_SLOTS` and related) or more memory may reduce it.",
          cannot_see: %w[ruby_gc_env] }
      end

      # Lines with provisioned-concurrency init are left out: that Init is not user-facing.
      rule("lambda_init_near_limit") do |c|
        next unless c.lambda?
        set = c.ok_p.select { |r| r.dig("platform", "kind") == "lambda" && r.dig("platform", "init_type") != "provisioned-concurrency" }
        ready = set.filter_map { |r| r.dig("phases_ms", "to_ready") }.grep(Numeric)
        init = c.init_ms.to_a
        timeouts = c.init_reports.to_a.select { |h| h["status"] == "timeout" }.sum { |h| h["count"] }
        ready_p90 = ready.size >= MIN_N ? Stats.percentile(ready, 90) : nil
        init_p90 = init.size >= MIN_N ? Stats.percentile(init, 90) : nil
        near = [ready_p90, init_p90].compact.any? { |v| v >= LAMBDA_NEAR_MS }
        next if timeouts.zero? && !near
        parts = []
        parts << "slowest Init #{sec(init.max)} s" unless init.empty?
        parts << "Init p90 #{sec(init_p90)} s" if init_p90
        parts << "to_ready p90 #{sec(ready_p90)} s" if ready_p90
        nums = parts.empty? ? "" : "#{parts.join(", ")} "
        msg = if timeouts.positive?
                "Init likely ran into the 10 s Lambda limit: #{timeouts} timeout(s); #{nums}(n=#{set.size}). " \
                  "A timed-out Init is retried within the first invoke, and that cold start has no hayaoki line " \
                  "(#{c.ok.size} ok lines for #{init.size} Init reports)."
              else
                "Init is likely close to the 10 s Lambda limit: #{nums}(n=#{set.size})."
              end
        msg += " Options: more memory (more CPU during Init); if `AWS_LWA_ASYNC_INIT` is not set, consider " \
               "`AWS_LWA_ASYNC_INIT=true` so LWA ends Init before the limit and finishes the readiness check in the first invoke; " \
               "bootsnap with its cache in the image."
        msg += " A timeout right after a deploy can be the first pull of a new image; check whether it repeats." unless near
        { level: "likely", n: set.size,
          evidence: { "timeouts" => timeouts, "init_ms_max" => init.max && Stats.rnd(init.max), "init_ms_p90" => init_p90 && Stats.rnd(init_p90),
                      "ready_ms_p90" => ready_p90, "init_reports" => init.size, "lines" => c.ok.size },
          message: msg, cannot_see: %w[aws_lwa_async_init image_pull] }
      end

      # Reads every ok line: the rejected or implausible starts are what it reports on.
      rule("prestarted_process") do |c|
        n = c.ok.size
        bad = c.ok.select { |r| implausible?(r) }
        next if n < MIN_N || bad.size * 2 < n
        pre = bad.filter_map { |r| r.dig("start_rejected", "pre_load_ms") || r.dig("phases_ms", "pre_load") }.grep(Numeric).select(&:positive?)
        p50 = median(pre)
        { level: "note", n: n, evidence: { "rejected" => bad.size, "pre_load_ms_p50" => p50 },
          message: "In #{bad.size} of #{n} lines the process started long before hayaoki loaded#{" (pre_load #{duration(p50)})" if p50}. " \
                   "The platform probably started the process ahead of the request and froze or throttled it (Cloud Run gen2 does this). " \
                   "Read the \"(from load)\" rows; the time before load is not user-visible boot.",
          cannot_see: %w[cpu_allocation] }
      end
    end
  end
end
