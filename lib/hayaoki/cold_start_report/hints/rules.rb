# frozen_string_literal: true

module Hayaoki
  module ColdStartReport
    module Hints
      LAMBDA_NEAR_MS = 7000 # Q7: p90 of Init / to_ready at or above this is "near" the 10 s limit
      GC_SHARE = 0.20
      CPU_BOUND_BUSY = 0.70 # median busy at or above: cpu_bound_boot
      WAIT_BUSY = 0.50      # median busy at or below: wait_dominated_boot
      # wait_dominated_boot split (resource-hints.md §3.2): median over the lines that waited of
      # main-thread run-queue wait / time off CPU.
      RUNQ_CPU_WAIT = 0.50  # at or above: the wait was mostly for a CPU
      RUNQ_NOT_CPU = 0.20   # at or below: the wait was not for a CPU
      WAIT_MAIN_CAUSE = 0.50 # PSI io stall (or steal) / time off CPU at or above: named as the likely main cause
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
        busy = shares.map { |s| c.busy(s[:share], quota) }
        { set: set, n: set.size, quota: quota,
          busy: median(busy),
          waited: busy.count { _1 <= WAIT_BUSY }, # lines that would read as wait-dominated on their own
          share: median(shares.map { _1[:share] }),
          cpu_ms: median(shares.map { _1[:cpu_ms] }), wall_ms: median(shares.map { _1[:wall_ms] }),
          from_load: shares.count { _1[:from_load] },
          runq_wait_ms: median(set.filter_map { |r| c.main_thread_runq_wait_ms(r) }) }
      end

      # main_thread_runq_wait_ms_p50 is the main thread's run-queue wait from load to emit (issue #12);
      # nil for lines without the field. Not comparable one to one with cpu_ms (all threads).
      def self.cpu_evidence(s)
        { "busy_p50" => s[:busy].round(2), "share_p50" => s[:share].round(2),
          "cpu_ms_p50" => Stats.rnd(s[:cpu_ms]), "wall_ms_p50" => Stats.rnd(s[:wall_ms]),
          "quota" => s[:quota]&.round(2), "quota_source" => s[:quota] ? "cgroup" : "unknown",
          "from_load_lines" => s[:from_load], "waited_lines" => s[:waited],
          "main_thread_runq_wait_ms_p50" => Stats.rnd(s[:runq_wait_ms]) }
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
        # The median hides lines that waited (gen1 minimal: 0.40 and 0.44 next to a 0.72 median); say so.
        msg += " #{s[:waited]} of #{s[:n]} lines waited instead: on CPU #{(WAIT_BUSY * 100).round}% of the time or less." if s[:waited].positive?
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

      WAIT_COUNTERS = %w[majflt io_read_bytes steal_ms psi_io_some_ms psi_cpu_some_ms].freeze
      GVISOR_ZERO_COUNTERS = %w[majflt io_read_bytes steal_ms].freeze

      # What the time off CPU was, over the lines that waited (busy at or under WAIT_BUSY, read from
      # load). :kind is "cpu" / "not_cpu" / "mixed" from the run-queue share, or nil when fewer than
      # MIN_N of those lines carry the run-queue fields (0.3.1 lines, gVisor, forked workers).
      # The counters are medians of emit - load; :unaccounted is what run queue, IO stall and steal
      # leave over, only where a line has all three.
      def self.wait_stats(c, s)
        rows = s[:set].filter_map do |r|
          non = c.non_cpu_ms(r) or next
          next if c.busy(c.share(r)[:share], s[:quota]) > WAIT_BUSY
          h = { non_cpu: non, runq: c.main_thread_runq_wait_ms(r) }
          WAIT_COUNTERS.each { |k| h[k] = c.proc_delta(r, k) }
          h
        end
        med = ->(set, &f) { median(set.filter_map(&f)) }
        rq = rows.select { _1[:runq] }
        out = { lines: rows.size, runq_lines: rq.size, non_cpu: med.(rows) { _1[:non_cpu] } }
        # gVisor reports 0 for these whatever happened (0.4.3 on Cloud Run gen1), so they say nothing there
        skip = c.gvisor?(s[:set]) ? GVISOR_ZERO_COUNTERS : []
        (WAIT_COUNTERS - skip).each { |k| out[k] = med.(rows) { _1[k] } }
        out[:io_share] = med.(rows) { |h| h["psi_io_some_ms"] && [h["psi_io_some_ms"].to_f / h[:non_cpu], 1.0].min }
        nproc = median(s[:set].filter_map { |r| c.num(r.dig("limits", "nproc")) })
        out[:nproc] = nproc&.positive? ? nproc : nil
        # steal is summed over all CPUs, so it is compared per CPU; without nproc there is no share
        out[:steal_share] = out[:nproc] && med.(rows) { |h| h["steal_ms"] && [h["steal_ms"].to_f / out[:nproc] / h[:non_cpu], 1.0].min }
        # PSI and steal are system-wide: they name a cause only where the instance is alone on its
        # VM or sandbox (Lambda, Cloud Run)
        out[:single_tenant] = c.lambda? || s[:set].count { _1.dig("platform", "kind") == "cloud_run" } * 2 >= s[:set].size
        out[:unaccounted] = med.(rq) { |h| h["psi_io_some_ms"] && h["steal_ms"] && [h[:non_cpu] - h[:runq] - h["psi_io_some_ms"] - h["steal_ms"], 0].max }
        return out if rq.size < MIN_N
        share = median(rq.map { [_1[:runq].to_f / _1[:non_cpu], 1.0].min })
        out.merge(runq: median(rq.map { _1[:runq] }), runq_non_cpu: median(rq.map { _1[:non_cpu] }), runq_share: share,
                  kind: share >= RUNQ_CPU_WAIT ? "cpu" : (share <= RUNQ_NOT_CPU ? "not_cpu" : "mixed"))
      end

      def self.wait_evidence(w)
        { "wait_kind" => w[:kind] || "unknown", "wait_lines" => w[:lines], "non_cpu_ms_p50" => Stats.rnd(w[:non_cpu]),
          "runq_share_of_non_cpu_p50" => w[:runq_share]&.round(2),
          "majflt_p50" => w["majflt"], "io_read_bytes_p50" => w["io_read_bytes"], "steal_ms_p50" => Stats.rnd(w["steal_ms"]),
          "psi_io_some_ms_p50" => Stats.rnd(w["psi_io_some_ms"]), "psi_cpu_some_ms_p50" => Stats.rnd(w["psi_cpu_some_ms"]),
          "unaccounted_ms_p50" => Stats.rnd(w[:unaccounted]) }
      end

      # " Over the same span (median): ..." or "" when no line has the counters. io_read_bytes is left
      # out at 0: overlay, FUSE and virtiofs report 0 whatever was read.
      def self.wait_counter_text(w)
        parts = []
        parts << "#{w["majflt"]} major page faults" if w["majflt"]
        parts << "#{(w["io_read_bytes"] / 1_048_576.0).round(1)} MB read from storage" if w["io_read_bytes"]&.positive?
        parts << "system-wide IO stall (PSI) #{span_text(w["psi_io_some_ms"])}" if w["psi_io_some_ms"]&.positive?
        if w["steal_ms"]&.positive?
          parts << "system-wide steal #{span_text(w["steal_ms"])}#{" summed over #{w[:nproc].round} CPUs" if w[:nproc]}"
        end
        parts.empty? ? "" : " Over the same span (median): #{parts.join(", ")}."
      end

      WAIT_CAUSES = "file IO (no bootsnap cache, many small files, lazily pulled image layers), " \
                    "network calls during boot (DB, secrets, HTTP in initializers)"

      # One id, four texts (evidence "wait_kind"): the trigger is the same, and the split depends on
      # fields that old lines and gVisor do not have. "unknown" is the 0.4.2 text.
      rule("wait_dominated_boot") do |c|
        s = cpu_stats(c) or next
        next if s[:busy] > WAIT_BUSY
        pct = (s[:busy] * 100).round
        lambda = c.lambda?
        gvisor = c.gvisor?(s[:set])
        w = wait_stats(c, s)
        kind = w[:kind]
        msg = "Boot likely spent most of its time waiting, not computing: on CPU #{pct}% of the time #{span(s)} " \
              "(median of #{s[:n]}; CPU #{sec(s[:cpu_ms])} s of #{sec(s[:wall_ms])} s)."
        runq = kind && "the main thread waited in the run queue for #{span_text(w[:runq])} of the #{span_text(w[:runq_non_cpu])} off CPU " \
                       "(median of #{w[:runq_lines]} lines that waited)"
        case kind
        when "cpu"
          msg += " Most of the wait was for a CPU: #{runq}. A CPU quota or other work on the same CPUs likely held boot back."
          msg += if lambda
                   " Init CPU does not follow the memory setting, so the remaining fix is less CPU work at boot: see `hayaoki boot-report`."
                 elsif s[:quota].nil? || s[:quota] < 1
                   " More CPU (cpu=1 or more) or startup CPU boost may help."
                 else
                   " A higher CPU limit or startup CPU boost may help."
                 end
        when "not_cpu"
          msg += " It was not waiting for a CPU: #{runq}, so throttling by a CPU quota is unlikely and more CPU is unlikely to help."
          if w[:single_tenant] && w[:io_share] && w[:io_share] >= WAIT_MAIN_CAUSE
            msg += " IO stall time (PSI) covers most of the wait, so file IO is the likely main cause (no bootsnap cache, many small files, lazily pulled image layers)."
          elsif w[:single_tenant] && w[:steal_share] && w[:steal_share] >= WAIT_MAIN_CAUSE
            msg += " Steal time covers most of the wait: the host likely did not run the instance's vCPUs for that time, which the app cannot change."
          else
            msg += " Likely causes: #{WAIT_CAUSES}, or the platform pausing the instance."
          end
        when "mixed"
          msg += " Part of the wait was for a CPU: #{runq}. More CPU may recover that part. Other likely causes: #{WAIT_CAUSES}."
        else
          msg += " More CPU is unlikely to help. Likely causes: #{WAIT_CAUSES}, or CPU throttled before the first request."
        end
        msg += wait_counter_text(w)
        if kind && kind != "cpu" && w[:unaccounted]&.positive?
          msg += " #{span_text(w[:unaccounted])} is in none of these counters: network wait, a paused instance, or file IO that PSI does not count (FUSE, virtiofs)."
        end
        cannot_see = %w[image_pull]
        unless lambda
          msg += " Try the other execution environment (gen1/gen2); file IO cost differs between them." unless kind == "cpu"
          msg += " The CPU quota is not visible; a quota below 1 vCPU would look like waiting." unless s[:quota] || kind
          cannot_see = %w[cpu_allocation image_pull]
          cannot_see.unshift("startup_cpu_boost") if kind == "cpu"
          cannot_see << "execution_environment" unless gvisor
        end
        msg += " gVisor system-call work is probably not counted as process CPU." if gvisor
        { level: "likely", n: s[:n], evidence: cpu_evidence(s).merge(wait_evidence(w)), message: msg, cannot_see: cannot_see }
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
