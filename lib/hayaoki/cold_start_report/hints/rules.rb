# frozen_string_literal: true

module Hayaoki
  module ColdStartReport
    module Hints
      LAMBDA_NEAR_MS = 7000 # Q7: p90 of Init / to_ready at or above this is "near" the 10 s limit
      GC_SHARE = 0.20
      CPU_BOUND_BUSY = 0.70 # median busy at or above: cpu_bound_boot
      WAIT_BUSY = 0.50      # median busy at or below: wait_dominated_boot
      MEM_P50 = 0.80        # median rss / limit
      MEM_ANY = 0.90        # any single line rss / limit

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

      # Shared by the two CPU rules: medians over c.cpu_set, or nil when a gate fails.
      def self.cpu_stats(c)
        set = c.cpu_set
        return nil if set.size < MIN_N || !c.g_ready?(set)
        shares = set.map { |r| c.share(r) }
        quota = c.quota(set)
        { set: set, n: set.size, quota: quota,
          busy: median(shares.map { |s| c.busy(s[:share], quota) }),
          share: median(shares.map { _1[:share] }),
          cpu_ms: median(shares.map { _1[:cpu_ms] }), wall_ms: median(shares.map { _1[:wall_ms] }),
          from_load: shares.count { _1[:from_load] } }
      end

      def self.cpu_evidence(s)
        { "busy_p50" => s[:busy].round(2), "share_p50" => s[:share].round(2),
          "cpu_ms_p50" => Stats.rnd(s[:cpu_ms]), "wall_ms_p50" => Stats.rnd(s[:wall_ms]),
          "quota" => s[:quota]&.round(2), "quota_source" => s[:quota] ? "cgroup" : "unknown",
          "from_load_lines" => s[:from_load] }
      end

      def self.span(s) = s[:from_load] == s[:n] ? "from load to first response" : "to first response"

      # Lambda is at most `possible`: the quota is unknown there and Init reportedly gets CPU independent
      # of the memory setting (§9 Q2 revised), so more memory is not the suggested fix.
      rule("cpu_bound_boot") do |c|
        s = cpu_stats(c) or next
        next if s[:busy] < CPU_BOUND_BUSY
        quota = s[:quota]
        lambda = c.lambda?
        level = !lambda && quota && quota < 1.0 ? "likely" : "possible"
        pct = (s[:busy] * 100).round
        msg = "Boot was likely CPU-bound: the process was on CPU #{pct}% of the time #{span(s)} " \
              "(median of #{s[:n]}; CPU #{sec(s[:cpu_ms])} s of #{sec(s[:wall_ms])} s; quota #{quota ? "#{quota.round(2)} vCPU" : "unknown"})."
        cannot_see = []
        if lambda
          msg += " Init reportedly gets CPU independent of the memory setting, so more memory is unlikely to shorten Init. " \
                 "The remaining fix is less CPU work at boot: see `hayaoki boot-report`."
        elsif level == "likely"
          msg += " More CPU will likely shorten boot: cpu=1 or more, and startup CPU boost."
          cannot_see = %w[startup_cpu_boost cpu_allocation]
        else
          msg += " The process already uses about one core, and Ruby boot runs mostly on one thread, so more vCPU alone probably helps little."
          msg += " On gVisor (gen1) sandbox work shares the same CPU quota, so more vCPU can still help there." if c.gvisor?(s[:set])
          msg += " The CPU quota is not visible, so a throttled CPU would look the same." unless quota
          msg += " If startup CPU boost is not on, turn it on. Otherwise the remaining fix is less CPU work at boot: see `hayaoki boot-report`."
          cannot_see = %w[startup_cpu_boost cpu_allocation]
        end
        { level: level, n: s[:n], evidence: cpu_evidence(s), message: msg, cannot_see: cannot_see }
      end

      rule("wait_dominated_boot") do |c|
        s = cpu_stats(c) or next
        next if s[:busy] > WAIT_BUSY
        pct = (s[:busy] * 100).round
        lambda = c.lambda?
        gvisor = c.gvisor?(s[:set])
        msg = "Boot likely spent most of its time waiting, not computing: on CPU #{pct}% of the time #{span(s)} " \
              "(median of #{s[:n]}; CPU #{sec(s[:cpu_ms])} s of #{sec(s[:wall_ms])} s). More CPU is unlikely to help. " \
              "Likely causes: file IO (no bootsnap cache, many small files, lazily pulled image layers), " \
              "network calls during boot (DB, secrets, HTTP in initializers), or CPU throttled before the first request."
        cannot_see = %w[image_pull]
        unless lambda
          msg += " Try the other execution environment (gen1/gen2); file IO cost differs between them."
          msg += " The CPU quota is not visible; a quota below 1 vCPU would look like waiting." unless s[:quota]
          cannot_see = %w[cpu_allocation image_pull]
          cannot_see << "execution_environment" unless gvisor
        end
        msg += " gVisor system-call work is probably not counted as process CPU." if gvisor
        { level: "likely", n: s[:n], evidence: cpu_evidence(s), message: msg, cannot_see: cannot_see }
      end

      # Reads every ok line: RSS at emit does not depend on the start. The limit is limits.mem_max_mb,
      # else platform.memory_mb (Lambda has no cgroup files). RSS at emit is not the peak, so short
      # peaks are missed (false negative, not false positive).
      rule("memory_near_limit") do |c|
        rows = c.ok.filter_map do |r|
          rss = c.num(r.dig("proc", "rss_kb"))
          limit = c.num(r.dig("limits", "mem_max_mb")) || c.num(r.dig("platform", "memory_mb"))
          next unless rss && limit&.positive?
          [rss / 1024.0, limit, rss / 1024.0 / limit, r.dig("limits", "mem_max_mb") ? "cgroup" : "platform"]
        end
        next if rows.size < MIN_N
        ratio = median(rows.map { _1[2] })
        worst = rows.max_by { _1[2] }
        next if ratio < MEM_P50 && worst[2] < MEM_ANY
        rss = median(rows.map { _1[0] })
        limit = median(rows.map { _1[1] })
        msg = "RSS at first response was #{rss.round} MB of #{limit.round} MB (#{(ratio * 100).round}%"
        msg += "; the highest line #{worst[0].round} MB of #{worst[1].round} MB, #{(worst[2] * 100).round}%" if worst[2] >= MEM_ANY && ratio < MEM_P50
        msg += "). The instance is likely close to its memory limit; GC work and OOM restarts rise near it. Consider more memory."
        { level: "likely", n: rows.size,
          evidence: { "rss_mb_p50" => rss.round, "limit_mb" => Stats.rnd(limit), "ratio_p50" => ratio.round(2),
                      "ratio_max" => worst[2].round(2), "limit_source" => rows.map { _1[3] }.tally.max_by { _2 }.first },
          message: msg }
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
        # No "more memory" option: Init reportedly gets CPU independent of the memory setting (§9 Q2 revised).
        msg += " Options: if `AWS_LWA_ASYNC_INIT` is not set, consider " \
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
