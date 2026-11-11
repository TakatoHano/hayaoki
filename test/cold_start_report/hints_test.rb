# frozen_string_literal: true

require "test_helper"
require "hayaoki/cold_start_report/runner"

class HintsTest < Minitest::Test
  H = Hayaoki::ColdStartReport::Hints

  # Synthetic cold_start line with placeholder values only (service svc, revision svc-00001-abc, function fn).
  # limits: nil = 0.2 line without the object; CR / LAMBDA below are 0.3.1-style objects.
  # rejected: like the emitter, pre_load is nil and the phases and marks count from load.
  def line(platform: :lambda, memory_mb: 1024, ready: 6800, cpu: 5400, gc_ms: 500, gc_count: 20, bootsnap: false,
           bootsnap_cache: nil, pre_load: 400, rejected: false, status: "ok", revision: "svc-00001-abc", init_type: "on-demand",
           cpu_at_load: nil, limits: nil, rss_kb: 200_000, worker: false, runq_wait: nil, runq_wait_at_load: nil)
    plat = if platform == :lambda
             { "kind" => "lambda", "function" => "fn", "memory_mb" => memory_mb, "init_type" => init_type }
           else
             { "kind" => "cloud_run", "service" => "svc", "revision" => revision }
           end
    loaded = rejected ? 0 : pre_load
    rec = { "hayaoki" => "cold_start", "v" => 1, "status" => status, "worker" => worker, "platform" => plat,
            "runtime" => { "bootsnap" => bootsnap, "bootsnap_cache" => bootsnap_cache },
            "phases_ms" => { "pre_load" => rejected ? nil : pre_load, "to_ready" => ready, "to_first_response" => ready + 200 },
            "marks_ms" => { "loaded" => loaded, "first_response_end" => ready + 200 },
            "proc" => { "cpu_ms" => cpu, "cpu_at_load_ms" => cpu_at_load, "gc_time_ms" => gc_ms, "gc_count" => gc_count, "rss_kb" => rss_kb,
                        "main_thread_runq_wait_ms" => runq_wait, "main_thread_runq_wait_at_load_ms" => runq_wait_at_load } }
    rec["limits"] = limits if limits
    rec["start_rejected"] = { "reason" => "pre_load_over_limit", "pre_load_ms" => 3_600_000 } if rejected
    rec
  end

  def lines(n, **kw) = Array.new(n) { line(**kw) }

  # Cloud Run / Lambda limits objects as 0.3.1 writes them
  def cr(quota: 2, sandbox: "gvisor", mem: 1024) = { "cgroup" => "v1", "cpu_quota" => quota, "nproc" => 2, "mem_max_mb" => mem, "sandbox" => sandbox }

  LAMBDA = { "cgroup" => nil, "cpu_quota" => nil, "nproc" => 2, "mem_max_mb" => nil, "sandbox" => nil }.freeze

  # Lines with a given CPU share from load: wall = to_first_response - pre_load = ready + 200 - 400,
  # cpu_at_load 100. ready 7000 gives a 6800 ms wall.
  def shared(n, share, platform: :cloud_run, limits: nil, ready: 7000, **kw)
    limits ||= platform == :lambda ? LAMBDA : cr
    wall = ready + 200 - (kw[:rejected] ? 0 : 400)
    lines(n, platform: platform, limits: limits, ready: ready, cpu_at_load: 100, cpu: 100 + (share * wall).round, bootsnap: true, bootsnap_cache: true, **kw)
  end

  def hints(records, **kw) = H.evaluate(records, **kw)[1]

  def ids(records, **kw) = hints(records, **kw).map(&:id)

  def hint(records, id, **kw) = hints(records, **kw).find { _1.id == id }

  def timeout = [{ "phase" => "init", "status" => "timeout", "count" => 1 }]

  # --- bootsnap_off

  def test_bootsnap_off_threshold
    assert_includes ids(lines(2, bootsnap: false) + lines(2, bootsnap: true, bootsnap_cache: true)), "bootsnap_off"
    refute_includes ids(lines(2, bootsnap: false) + lines(3, bootsnap: true, bootsnap_cache: true)), "bootsnap_off"
    h = hint(lines(3, bootsnap: false), "bootsnap_off")
    assert_equal ["likely", 3, { "off" => 3 }], [h.level, h.n, h.evidence]
    assert_match(/not loaded in 3 of 3 cold starts/, h.message)
  end

  def test_bootsnap_off_gates_and_implausible
    refute_includes ids(lines(2, bootsnap: false)), "bootsnap_off"
    refute_includes ids(lines(2, bootsnap: false) + lines(3, bootsnap: false, pre_load: 700_000)), "bootsnap_off"
    refute_includes ids(lines(2, bootsnap: false) + lines(3, bootsnap: false, rejected: true)), "bootsnap_off"
    refute_includes ids(lines(3, bootsnap: false, status: "no_request")), "bootsnap_off"
    # not a resource rule: no G_ready
    assert_includes ids(lines(3, bootsnap: false, ready: 1000)), "bootsnap_off"
  end

  # --- bootsnap_cache_cold

  def test_bootsnap_cache_cold_threshold
    cold = { bootsnap: true, bootsnap_cache: false }
    warm = { bootsnap: true, bootsnap_cache: true }
    assert_includes ids(lines(2, **cold) + lines(2, **warm)), "bootsnap_cache_cold"
    refute_includes ids(lines(2, **cold) + lines(3, **warm)), "bootsnap_cache_cold"
    h = hint(lines(3, **cold), "bootsnap_cache_cold")
    assert_match(/in 3 of 3 cold starts/, h.message)
    assert_match(/read-only/, h.message)
    refute_match(/read-only/, hint(lines(3, platform: :cloud_run, **cold), "bootsnap_cache_cold").message)
  end

  def test_bootsnap_cache_cold_ignores_null_and_implausible
    cold = { bootsnap: true, bootsnap_cache: false }
    refute_includes ids(lines(2, **cold) + lines(3, bootsnap: true, bootsnap_cache: nil)), "bootsnap_cache_cold"
    refute_includes ids(lines(2, **cold) + lines(2, **cold, pre_load: -5)), "bootsnap_cache_cold"
    refute_includes ids(lines(3, bootsnap: false, bootsnap_cache: false)), "bootsnap_cache_cold"
  end

  # --- gc_pressure

  def test_gc_pressure_threshold
    assert_includes ids(lines(3, cpu: 5000, gc_ms: 1000, bootsnap: true)), "gc_pressure"
    refute_includes ids(lines(3, cpu: 5000, gc_ms: 999, bootsnap: true)), "gc_pressure"
    h = hint(lines(3, cpu: 5000, gc_ms: 1000, gc_count: 30), "gc_pressure")
    assert_equal "possible", h.level
    assert_equal({ "gc_share_p50" => 0.2, "gc_ms_p50" => 1000, "cpu_ms_p50" => 5000, "gc_count_p50" => 30 }, h.evidence)
    assert_match(/GC took 20% of boot CPU \(median 1000 ms of 5000 ms, 30 GCs\)/, h.message)
  end

  def test_gc_pressure_gates
    refute_includes ids(lines(2, cpu: 5000, gc_ms: 2000)), "gc_pressure"
    refute_includes ids(lines(3, cpu: 5000, gc_ms: 2000, ready: 2999)), "gc_pressure"
    assert_includes ids(lines(3, cpu: 5000, gc_ms: 2000, ready: 3000)), "gc_pressure"
    refute_includes ids(lines(2, cpu: 5000, gc_ms: 2000) + lines(3, cpu: 5000, gc_ms: 2000, pre_load: 700_000)), "gc_pressure"
  end

  # --- prestarted_process

  def test_prestarted_process
    h = hint(lines(3, rejected: true) + lines(3), "prestarted_process")
    assert_equal ["note", 6, 3], [h.level, h.n, h.evidence["rejected"]]
    assert_match(/In 3 of 6 lines .* \(pre_load 60 min\)/, h.message)
    refute_includes ids(lines(2, rejected: true) + lines(3)), "prestarted_process"
    assert_includes ids(lines(3, pre_load: 7_200_000)), "prestarted_process"
    refute_includes ids(lines(2, rejected: true)), "prestarted_process"
  end

  # --- lambda_init_near_limit

  def test_lambda_near_limit_threshold
    assert_includes ids(lines(3, ready: 7000)), "lambda_init_near_limit"
    refute_includes ids(lines(3, ready: 6999)), "lambda_init_near_limit"
    assert_includes ids(lines(3, ready: 5000), init_ms: [5000.0, 6000.0, 7000.0]), "lambda_init_near_limit"
    refute_includes ids(lines(3, ready: 5000), init_ms: [5000.0, 6000.0, 6999.0]), "lambda_init_near_limit"
    refute_includes ids(lines(3, platform: :cloud_run, ready: 9000)), "lambda_init_near_limit"
    h = hint(lines(3, ready: 7000), "lambda_init_near_limit")
    assert_equal "likely", h.level
    assert_match(/close to the 10 s Lambda limit: to_ready p90 7.0 s \(n=3\)/, h.message)
    assert_match(/if `AWS_LWA_ASYNC_INIT` is not set, consider/, h.message)
    refute_match(/more memory/, h.message) # Q2 revised: Init CPU does not follow the memory setting
  end

  def test_lambda_timeout_needs_no_g_n
    h = hint(lines(1, ready: 5000), "lambda_init_near_limit", init_ms: [9999.6], init_reports: timeout)
    assert_equal 1, h.evidence["timeouts"]
    assert_match(/ran into the 10 s Lambda limit: 1 timeout\(s\); slowest Init 10.0 s \(n=1\)/, h.message)
    assert_match(/check whether it repeats/, h.message)
    refute_match(/repeats/, hint(lines(3, ready: 9000), "lambda_init_near_limit", init_reports: timeout).message)
    refute_includes ids(lines(2, ready: 9000)), "lambda_init_near_limit"
  end

  def test_lambda_excludes_provisioned_and_implausible
    refute_includes ids(lines(3, ready: 9000, init_type: "provisioned-concurrency")), "lambda_init_near_limit"
    refute_includes ids(lines(2, ready: 9000) + lines(3, ready: 9000, pre_load: 700_000)), "lambda_init_near_limit"
  end

  # --- cpu_bound_boot

  def test_cpu_bound_threshold_and_evidence
    assert_includes ids(shared(3, 0.70)), "cpu_bound_boot"
    refute_includes ids(shared(3, 0.70).each { _1["proc"]["cpu_ms"] -= 1 }), "cpu_bound_boot"
    h = hint(shared(3, 0.75), "cpu_bound_boot")
    assert_equal "possible", h.level # quota 2 >= 1
    assert_equal({ "busy_p50" => 0.75, "share_p50" => 0.75, "cpu_ms_p50" => 5100, "wall_ms_p50" => 6800, "quota" => 2.0,
                   "quota_source" => "cgroup", "from_load_lines" => 3, "waited_lines" => 0, "main_thread_runq_wait_ms_p50" => nil }, h.evidence)
    assert_match(/on CPU 75% of the time from load to first response \(median of 3; CPU 5.1 s of 6.8 s; quota 2.0 vCPU\)\. The process already/, h.message)
    refute_match(/waited/, h.message)
    assert_match(/already uses about one core/, h.message)
    assert_match(/gVisor \(gen1\) sandbox work shares the same CPU quota/, h.message)
    assert_match(/If startup CPU boost is not on/, h.message)
    refute_match(/quota is not visible/, h.message)
    assert_equal %w[startup_cpu_boost cpu_allocation], h.cannot_see
    refute_match(/gVisor/, hint(shared(3, 0.75, limits: cr(sandbox: nil)), "cpu_bound_boot").message)
  end

  # Issue #12: the gen1 minimal cell (shares 0.40 0.44 0.72 0.75 0.77 0.78, median 0.72) fires cpu_bound_boot
  # although two lines waited. The text and evidence say how many lines were at or under WAIT_BUSY.
  def test_cpu_bound_counts_lines_that_waited
    recs = [0.40, 0.44, 0.72, 0.75, 0.77, 0.78].flat_map { shared(1, _1) }
    h = hint(recs, "cpu_bound_boot")
    assert_equal [0.72, 2], [h.evidence["busy_p50"], h.evidence["waited_lines"]]
    assert_match(/quota 2.0 vCPU\)\. 2 of 6 lines waited instead: on CPU 50% of the time or less\. The process already/, h.message)
    refute_includes ids(recs), "wait_dominated_boot"
    # a line just over WAIT_BUSY does not count; busy (not share) is compared, so a quota below 1 scales it
    assert_equal 0, hint(shared(2, 0.9) + shared(1, 0.51), "cpu_bound_boot").evidence["waited_lines"]
    assert_equal 1, hint(shared(2, 0.45, limits: cr(quota: 0.5)) + shared(1, 0.25, limits: cr(quota: 0.5)), "cpu_bound_boot").evidence["waited_lines"]
    # wait_dominated_boot carries the same count
    assert_equal 3, hint(shared(3, 0.3), "wait_dominated_boot").evidence["waited_lines"]
  end

  # Main-thread run-queue wait from load to emit: median over lines with both fields; nil otherwise.
  def test_cpu_evidence_main_thread_runq_wait
    recs = shared(1, 0.9, runq_wait: 1500, runq_wait_at_load: 20) + shared(1, 0.9, runq_wait: 900, runq_wait_at_load: 10) +
           shared(1, 0.9, runq_wait: 400, runq_wait_at_load: 5)
    assert_equal 890, hint(recs, "cpu_bound_boot").evidence["main_thread_runq_wait_ms_p50"]
    # a forked child (at_load null) and a line with the emit value below the load value are left out
    recs = shared(2, 0.3, runq_wait: 3000, runq_wait_at_load: 100) + shared(1, 0.3, runq_wait: 500, worker: true) +
           shared(1, 0.3, runq_wait: 50, runq_wait_at_load: 100)
    assert_equal 2900, hint(recs, "wait_dominated_boot").evidence["main_thread_runq_wait_ms_p50"]
    assert_nil hint(shared(3, 0.3, runq_wait: 500), "wait_dominated_boot").evidence["main_thread_runq_wait_ms_p50"]
  end

  def test_cpu_bound_quota_below_one_is_likely_and_busy_clamps
    # quota 0.5: share 0.35 is busy 0.70
    h = hint(shared(3, 0.35, limits: cr(quota: 0.5)), "cpu_bound_boot")
    assert_equal ["likely", 0.7, 0.35, 0.5], [h.level, h.evidence["busy_p50"], h.evidence["share_p50"], h.evidence["quota"]]
    assert_match(/More CPU will likely shorten boot: cpu=1 or more, and startup CPU boost/, h.message)
    refute_includes ids(shared(3, 0.35, limits: cr(quota: 0.5)).each { _1["proc"]["cpu_ms"] -= 1 }), "cpu_bound_boot"
    h = hint(shared(3, 0.60, limits: cr(quota: 0.5)), "cpu_bound_boot")
    assert_equal [1.0, 0.6], [h.evidence["busy_p50"], h.evidence["share_p50"]]
    assert_match(/on CPU 100% of the time/, h.message)
    # quota 1.5 is clamped to 1 before dividing: share 0.70 stays busy 0.70
    assert_equal 0.7, hint(shared(3, 0.70, limits: cr(quota: 1.5)), "cpu_bound_boot").evidence["busy_p50"]
  end

  def test_cpu_bound_lambda_at_most_possible
    h = hint(shared(3, 0.99, platform: :lambda), "cpu_bound_boot")
    assert_equal "possible", h.level
    assert_equal [nil, "unknown"], [h.evidence["quota"], h.evidence["quota_source"]]
    assert_match(/quota unknown\)\. Init reportedly gets CPU independent of the memory setting/, h.message)
    assert_match(/hayaoki boot-report/, h.message)
    refute_match(/nominal|MB/, h.message)
    assert_equal [], h.cannot_see
    assert_equal "possible", hint(shared(3, 0.99, platform: :lambda, memory_mb: 512), "cpu_bound_boot").level
  end

  def test_cpu_bound_unknown_quota_on_cloud_run
    # 0.2 line: no limits object, no cpu_at_load_ms; share = cpu_ms / to_first_response (7000)
    recs = lines(3, platform: :cloud_run, ready: 6800, cpu: 4900, bootsnap: true, bootsnap_cache: true)
    h = hint(recs, "cpu_bound_boot")
    assert_equal ["possible", 0.7, "unknown", 0], [h.level, h.evidence["busy_p50"], h.evidence["quota_source"], h.evidence["from_load_lines"]]
    assert_match(/of the time to first response/, h.message)
    assert_match(/quota is not visible/, h.message)
  end

  def test_cpu_bound_gates
    refute_includes ids(shared(2, 0.9)), "cpu_bound_boot"
    refute_includes ids(shared(3, 0.9, ready: 2999)), "cpu_bound_boot"
    assert_includes ids(shared(3, 0.9, ready: 3000)), "cpu_bound_boot"
    # 0.2 implausible-start lines are skipped
    refute_includes ids(shared(2, 0.9) + lines(3, platform: :cloud_run, ready: 7000, cpu: 6000, pre_load: 700_000)), "cpu_bound_boot"
  end

  # --- wait_dominated_boot

  def test_wait_dominated_threshold
    assert_includes ids(shared(3, 0.50)), "wait_dominated_boot"
    refute_includes ids(shared(3, 0.50).each { _1["proc"]["cpu_ms"] += 1 }), "wait_dominated_boot"
    h = hint(shared(3, 0.29, limits: cr(quota: 1.97, sandbox: nil)), "wait_dominated_boot")
    assert_equal ["likely", 0.29, 1.97], [h.level, h.evidence["busy_p50"], h.evidence["quota"]]
    assert_match(/waiting, not computing: on CPU 29% of the time from load to first response \(median of 3; CPU 2.0 s of 6.8 s\)/, h.message)
    assert_match(/Try the other execution environment \(gen1\/gen2\)/, h.message)
    refute_match(/gVisor|quota is not visible/, h.message)
    assert_equal %w[cpu_allocation image_pull execution_environment], h.cannot_see
    h = hint(shared(3, 0.3), "wait_dominated_boot")
    assert_match(/gVisor system-call work is probably not counted/, h.message)
    assert_equal %w[cpu_allocation image_pull], h.cannot_see
    h = hint(shared(3, 0.3, platform: :lambda), "wait_dominated_boot")
    refute_match(/execution environment|gVisor/, h.message)
    assert_equal %w[image_pull], h.cannot_see
  end

  def test_wait_dominated_quota_and_gates
    # quota 0.5: share 0.25 is busy 0.50, fires; share 0.26 does not
    assert_includes ids(shared(3, 0.25, limits: cr(quota: 0.5))), "wait_dominated_boot"
    refute_includes ids(shared(3, 0.26, limits: cr(quota: 0.5))), "wait_dominated_boot"
    assert_match(/quota is not visible; a quota below 1 vCPU would look like waiting/,
                 hint(lines(3, platform: :cloud_run, ready: 6800, cpu: 2000), "wait_dominated_boot").message)
    refute_includes ids(shared(2, 0.3)), "wait_dominated_boot"
    refute_includes ids(shared(3, 0.3, ready: 2999)), "wait_dominated_boot"
  end

  def test_rejected_starts_with_cpu_at_load_are_read_from_load
    recs = shared(3, 0.29, limits: cr(quota: 1.97, sandbox: nil), rejected: true)
    assert_equal %w[wait_dominated_boot prestarted_process], ids(recs)
    h = hint(recs, "wait_dominated_boot")
    assert_equal [3, 3, 7200], [h.n, h.evidence["from_load_lines"], h.evidence["wall_ms_p50"]]
    assert_equal 0, H.evaluate(recs)[0] # ok_p stays empty; the from-load gate is what lets the rule run
    # from-load ready gate on rejected lines
    refute_includes ids(shared(3, 0.29, rejected: true, ready: 2999)), "wait_dominated_boot"
    # without cpu_at_load_ms a rejected start cannot be read: the share would include the frozen time
    refute_includes ids(lines(3, platform: :cloud_run, rejected: true, cpu: 2000, limits: cr)), "wait_dominated_boot"
    refute_includes ids(lines(3, platform: :cloud_run, rejected: true, cpu: 6000, limits: cr)), "cpu_bound_boot"
  end

  def test_forked_workers_without_cpu_at_load_are_skipped
    cpu = %w[cpu_bound_boot wait_dominated_boot]
    assert_empty ids(lines(3, platform: :cloud_run, worker: true, cpu: 6500, ready: 6800, bootsnap: true, bootsnap_cache: true)) & cpu
    assert_empty ids(shared(2, 0.9) + lines(1, platform: :cloud_run, worker: true, cpu: 6500, ready: 6800)) & cpu
    # a worker line with cpu_at_load_ms is usable
    assert_includes ids(shared(3, 0.9, worker: true)), "cpu_bound_boot"
  end

  def test_mixed_quota
    assert hint(shared(2, 0.9) + shared(2, 0.9, limits: cr(quota: 1)), "cpu_bound_boot").mixed
    refute hint(shared(2, 0.9, limits: cr(quota: 1.972)) + shared(2, 0.9, limits: cr(quota: 1.97)), "cpu_bound_boot").mixed
  end

  # --- wait_dominated_boot split (resource-hints.md §3.2)

  # Lines that waited (share 0.25, wall 6800, 5100 ms off CPU) with a run-queue wait of `runq` ms from
  # load to emit and optional proc counters: {"majflt" => [at_load, at_emit], ...}.
  def waited(n, runq:, counters: {}, **kw)
    shared(n, 0.25, limits: cr(quota: 2.086, sandbox: nil), runq_wait: runq && runq + 2, runq_wait_at_load: runq && 2, **kw).each do |r|
      counters.each do |k, (at_load, at_emit)|
        r["proc"][k] = at_emit
        r["proc"][k.end_with?("_ms") ? k.sub(/_ms\z/, "_at_load_ms") : "#{k}_at_load"] = at_load
      end
    end
  end

  def test_wait_split_not_cpu
    # gen2 0.4.1 shape: two fast lines, four that waited with 1 ms in the run queue
    h = hint(shared(2, 0.85, limits: cr(quota: 2.086, sandbox: nil), runq_wait: 3, runq_wait_at_load: 2) + waited(4, runq: 1), "wait_dominated_boot")
    assert_equal "likely", h.level
    assert_equal ["not_cpu", 4, 5100, 0.0], h.evidence.values_at("wait_kind", "wait_lines", "non_cpu_ms_p50", "runq_share_of_non_cpu_p50")
    assert_match(/It was not waiting for a CPU: the main thread waited in the run queue for 1 ms of the 5\.1 s off CPU \(median of 4 lines that waited\)/, h.message)
    assert_match(/throttling by a CPU quota is unlikely and more CPU is unlikely to help\. Likely causes: file IO .*network calls.*or the platform pausing the instance\./, h.message)
    refute_match(/CPU throttled before the first request|Over the same span|none of these counters/, h.message)
    assert_match(/Try the other execution environment/, h.message)
    assert_equal %w[cpu_allocation image_pull execution_environment], h.cannot_see
    %w[majflt_p50 io_read_bytes_p50 steal_ms_p50 psi_io_some_ms_p50 psi_cpu_some_ms_p50 unaccounted_ms_p50].each { assert_nil h.evidence.fetch(_1), _1 }
  end

  def test_wait_split_thresholds
    kind = ->(runq) { hint(waited(3, runq: runq), "wait_dominated_boot").evidence["wait_kind"] }
    # 5100 ms off CPU: 20% is 1020, 50% is 2550
    assert_equal %w[not_cpu mixed mixed cpu], [1020, 1021, 2549, 2550].map(&kind)
    # a run-queue wait longer than the time off CPU (main thread vs all threads) is clamped
    assert_equal 1.0, hint(waited(3, runq: 9000), "wait_dominated_boot").evidence["runq_share_of_non_cpu_p50"]
  end

  def test_wait_split_cpu
    h = hint(waited(3, runq: 4000), "wait_dominated_boot")
    assert_equal ["cpu", 0.78], h.evidence.values_at("wait_kind", "runq_share_of_non_cpu_p50")
    assert_match(/Most of the wait was for a CPU: the main thread waited in the run queue for 4\.0 s of the 5\.1 s off CPU/, h.message)
    # quota 2.086 (at least 1): more vCPU is not the advice
    assert_match(/A higher CPU limit or startup CPU boost may help\./, h.message)
    refute_match(/More CPU \(cpu=1/, h.message)
    refute_match(/unlikely to help|file IO|execution environment/, h.message)
    [0.5, nil].each do |q|
      m = hint(waited(3, runq: 4000, limits: cr(quota: q, sandbox: nil)), "wait_dominated_boot").message
      assert_match(/More CPU \(cpu=1 or more\) or startup CPU boost may help\./, m, q.inspect)
    end
    assert_equal %w[startup_cpu_boost cpu_allocation image_pull execution_environment], h.cannot_see
    h = hint(waited(3, runq: 4000, platform: :lambda, limits: LAMBDA), "wait_dominated_boot")
    assert_match(/Init CPU does not follow the memory setting/, h.message)
    refute_match(/startup CPU boost/, h.message)
    assert_equal %w[image_pull], h.cannot_see
  end

  def test_wait_split_mixed
    h = hint(waited(3, runq: 1800), "wait_dominated_boot")
    assert_equal "mixed", h.evidence["wait_kind"]
    assert_match(/Part of the wait was for a CPU: .*1\.8 s of the 5\.1 s off CPU.*More CPU may recover that part\. Other likely causes: file IO/, h.message)
  end

  # Fewer than 3 waited lines with the run-queue fields (0.3.1 lines, gVisor, forked workers): 0.4.2 text
  def test_wait_split_unknown_keeps_old_text
    [waited(3, runq: nil), waited(2, runq: 1) + waited(2, runq: nil)].each do |recs|
      h = hint(recs, "wait_dominated_boot")
      assert_equal "unknown", h.evidence["wait_kind"]
      assert_nil h.evidence["runq_share_of_non_cpu_p50"]
      assert_match(/\)\. More CPU is unlikely to help\. Likely causes: file IO .*or CPU throttled before the first request\. Try the other/, h.message)
      refute_match(/run queue/, h.message)
    end
    # the lines that did not wait are not read: one fast line with a long run-queue wait changes nothing
    recs = shared(1, 0.9, limits: cr(quota: 2.086, sandbox: nil), runq_wait: 900, runq_wait_at_load: 0) + waited(3, runq: 1)
    assert_equal ["not_cpu", 3], hint(recs, "wait_dominated_boot").evidence.values_at("wait_kind", "wait_lines")
  end

  def test_wait_split_counters_as_evidence
    c = { "majflt" => [10, 850], "io_read_bytes" => [0, 0], "steal_ms" => [100, 140], "psi_io_some_ms" => [50, 450], "psi_cpu_some_ms" => [5, 9] }
    h = hint(waited(3, runq: 1, counters: c), "wait_dominated_boot")
    assert_equal [840, 0, 40, 400, 4, 4659], h.evidence.values_at(*%w[majflt_p50 io_read_bytes_p50 steal_ms_p50 psi_io_some_ms_p50 psi_cpu_some_ms_p50 unaccounted_ms_p50])
    # read bytes of 0 are not shown (overlay / FUSE report 0); IO stall under half the wait does not name file IO as the cause
    assert_match(/or the platform pausing the instance\. Over the same span \(median\): 840 major page faults, system-wide IO stall \(PSI\) 400 ms, system-wide steal 40 ms summed over 2 CPUs\. 4\.7 s is in none of these counters: network wait, a paused instance, or file IO that PSI does not count/, h.message)
    refute_match(/MB read|likely main cause/, h.message)
    h = hint(waited(3, runq: 1, counters: { "io_read_bytes" => [1_048_576, 85_983_232] }), "wait_dominated_boot")
    assert_match(/Over the same span \(median\): 81\.0 MB read from storage\./, h.message)
    refute_match(/none of these counters|likely main cause/, h.message) # no PSI, no steal: nothing to subtract
    # counters also show with the old text (no run-queue fields), but no remainder
    h = hint(waited(3, runq: nil, counters: c), "wait_dominated_boot")
    assert_match(/before the first request\. Over the same span \(median\): 840 major page faults/, h.message)
    assert_nil h.evidence["unaccounted_ms_p50"]
  end

  def test_wait_split_names_file_io_or_steal_only_over_half
    io = ->(stall) { hint(waited(3, runq: 1, counters: { "psi_io_some_ms" => [0, stall], "steal_ms" => [0, 0] }), "wait_dominated_boot").message }
    assert_match(/IO stall time \(PSI\) covers most of the wait, so file IO is the likely main cause/, io.(2550))
    refute_match(/network calls/, io.(2550))
    refute_match(/likely main cause/, io.(2549))
    assert_match(/network calls/, io.(2549))
    # steal is summed over the 2 CPUs (nproc 2), so it is compared per CPU: 5100 / 2 is half of 5100 ms
    st = ->(steal) { hint(waited(3, runq: 1, counters: { "steal_ms" => [0, steal] }), "wait_dominated_boot").message }
    assert_match(/Steal time covers most of the wait: the host likely did not run the instance's vCPUs/, st.(5100))
    refute_match(/Steal time covers/, st.(5098))
    refute_match(/Steal time covers/, st.(2550))
    # with the wait on a CPU the counters are listed but not read as a cause
    refute_match(/likely main cause/, hint(waited(3, runq: 4000, counters: { "psi_io_some_ms" => [0, 3000] }), "wait_dominated_boot").message)
  end

  def test_wait_split_cause_needs_nproc_and_single_tenant
    io = { "psi_io_some_ms" => [0, 4000] }
    st = { "steal_ms" => [0, 5100] }
    # nproc unknown: steal cannot be read per CPU, so no steal sentence (the number still shows)
    no_nproc = hint(waited(3, runq: 1, counters: st, limits: cr(quota: 2.086, sandbox: nil).merge("nproc" => nil)), "wait_dominated_boot").message
    refute_match(/Steal time covers/, no_nproc)
    assert_match(/system-wide steal 5\.1 s\./, no_nproc)
    # not a Lambda / Cloud Run line: the numbers stay, the cause sentences do not
    other = ->(c) { waited(3, runq: 1, counters: c).each { _1["platform"]["kind"] = "other" } }
    m = hint(other.(io.merge(st)), "wait_dominated_boot").message
    refute_match(/likely main cause|Steal time covers/, m)
    assert_match(/system-wide IO stall \(PSI\) 4\.0 s, system-wide steal 5\.1 s summed over 2 CPUs\./, m)
    assert_match(/network calls/, m)
    assert_match(/likely main cause/, hint(waited(3, runq: 1, counters: io), "wait_dominated_boot").message)
    assert_match(/likely main cause/, hint(waited(3, runq: 1, counters: io, platform: :lambda, limits: LAMBDA), "wait_dominated_boot").message)
  end

  def test_wait_counter_text_skips_zero_steal_and_psi_and_zero_remainder
    c = { "majflt" => [0, 5], "steal_ms" => [0, 0], "psi_io_some_ms" => [0, 0], "psi_cpu_some_ms" => [0, 0] }
    m = hint(waited(3, runq: 1, counters: c), "wait_dominated_boot").message
    assert_match(/Over the same span \(median\): 5 major page faults\./, m)
    refute_match(/system-wide/, m)
    # off-CPU time fully explained by run queue, PSI and steal: no remainder sentence
    full = { "psi_io_some_ms" => [0, 4000], "steal_ms" => [0, 2200] }
    h = hint(waited(3, runq: 1000, counters: full), "wait_dominated_boot")
    assert_equal 0, h.evidence["unaccounted_ms_p50"]
    refute_match(/none of these counters/, h.message)
  end

  # --- memory_near_limit

  def test_memory_near_limit_threshold
    at = ->(ratio, limit = 1024) { (ratio * limit * 1024).ceil }
    recs = lines(3, platform: :cloud_run, limits: cr, rss_kb: at.(0.80))
    h = hint(recs, "memory_near_limit")
    assert_equal ["likely", 3], [h.level, h.n]
    assert_equal({ "rss_mb_p50" => 819, "limit_mb" => 1024, "ratio_p50" => 0.8, "ratio_max" => 0.8, "limit_source" => "cgroup" }, h.evidence)
    assert_match(/RSS at first response was 819 MB of 1024 MB \(80%\)\. The instance is likely close/, h.message)
    refute_includes ids(lines(3, platform: :cloud_run, limits: cr, rss_kb: at.(0.80) - 1)), "memory_near_limit"
    # any single line at 0.90
    recs = lines(2, platform: :cloud_run, limits: cr, rss_kb: at.(0.5)) + lines(1, platform: :cloud_run, limits: cr, rss_kb: at.(0.90))
    h = hint(recs, "memory_near_limit")
    assert_equal [0.5, 0.9], [h.evidence["ratio_p50"], h.evidence["ratio_max"]]
    assert_match(/\(50%; the highest line 922 MB of 1024 MB, 90%\)/, h.message)
    refute_includes ids(lines(2, platform: :cloud_run, limits: cr, rss_kb: at.(0.5)) + lines(1, platform: :cloud_run, limits: cr, rss_kb: at.(0.90) - 1)), "memory_near_limit"
  end

  def test_memory_near_limit_limit_source_and_gates
    at = ->(ratio, limit) { (ratio * limit * 1024).ceil }
    # Lambda: limits.mem_max_mb is null, platform.memory_mb is the limit
    h = hint(lines(3, limits: LAMBDA, memory_mb: 512, rss_kb: at.(0.85, 512)), "memory_near_limit")
    assert_equal ["platform", 512], [h.evidence["limit_source"], h.evidence["limit_mb"]]
    # 0.2 Cloud Run line: no limit anywhere
    refute_includes ids(lines(3, platform: :cloud_run, rss_kb: at.(0.95, 1024))), "memory_near_limit"
    refute_includes ids(lines(2, platform: :cloud_run, limits: cr, rss_kb: at.(0.95, 1024))), "memory_near_limit"
    # not a start-based rule: rejected and short boots count
    assert_includes ids(lines(3, platform: :cloud_run, limits: cr, rss_kb: at.(0.85, 1024), rejected: true, ready: 1000)), "memory_near_limit"
  end

  # --- frame

  def test_g_n_count_and_order
    n, list, = H.evaluate(lines(3, bootsnap: false, ready: 9000, cpu: 5000, gc_ms: 2000) + lines(1, pre_load: -1))
    assert_equal 3, n
    assert_equal %w[bootsnap_off lambda_init_near_limit gc_pressure], list.map(&:id)
    assert_equal [0, []], H.evaluate(lines(3, status: "boot_error"))[0..1]
  end

  def test_mixed
    recs = lines(2, platform: :cloud_run, bootsnap: false) + lines(2, platform: :cloud_run, bootsnap: false, revision: "svc-00002-abc")
    h = hint(recs, "bootsnap_off")
    assert h.mixed
    assert_equal ["platform.revision"], H.evaluate(recs)[2]
    refute hint(lines(4, bootsnap: false), "bootsnap_off").mixed
    assert hint(lines(2, bootsnap: false) + lines(2, bootsnap: false, memory_mb: 2048), "bootsnap_off").mixed
    assert hint(lines(2, bootsnap: false) + lines(1, bootsnap: true), "bootsnap_off").mixed
  end

  # --- calibration: per-cell medians of resource-hints.md §1 (0.2 lines, no new fields) must give the
  # hints of the first §3.1 table, read with Q2 revised: Lambda has no nominal quota, so Lambda Redmine
  # 1024 gets cpu_bound_boot `possible` (busy 0.76), not `likely`.

  def cell(n, implausible: 0, **kw) = lines(n - implausible, **kw) + lines(implausible, pre_load: 3_000_000, **kw)

  CAL = {
    "CR gen1 minimal" => [-> { _1.cell(6, implausible: 1, platform: :cloud_run, ready: 4900, cpu: 3600, gc_ms: 360, bootsnap: true, bootsnap_cache: true) }, nil, nil, %w[cpu_bound_boot]],
    "CR gen2 minimal" => [-> { _1.cell(6, implausible: 6, platform: :cloud_run, ready: 6500, cpu: 3800, gc_ms: 380, bootsnap: true, bootsnap_cache: true) }, nil, nil, %w[prestarted_process]],
    "CR gen1 Redmine" => [-> { _1.cell(6, platform: :cloud_run, ready: 20_300, cpu: 12_000, gc_ms: 600, bootsnap: false) }, nil, nil, %w[bootsnap_off]],
    "Lambda minimal 1024" => [-> { _1.cell(6, memory_mb: 1024, ready: 1800, cpu: 1500, gc_ms: 210, bootsnap: true, bootsnap_cache: true) }, [1800.0] * 5 + [3100.0], nil, []],
    "Lambda minimal 2048" => [-> { _1.cell(6, memory_mb: 2048, ready: 1900, cpu: 1600, gc_ms: 225, bootsnap: true, bootsnap_cache: true) }, [1900.0] * 5 + [2100.0], nil, []],
    "Lambda Redmine 1024" => [-> { _1.cell(4, memory_mb: 1024, ready: 6800, cpu: 5300, gc_ms: 480, bootsnap: false) + _1.lines(1, ready: 9300, cpu: 5400, gc_ms: 480, bootsnap: false) },
                              [6000.0, 6100.0, 6800.0, 7000.0, 9300.0, 10_000.0], :timeout, %w[bootsnap_off lambda_init_near_limit cpu_bound_boot]],
    "Lambda Redmine 2048" => [-> { _1.cell(6, memory_mb: 2048, ready: 5600, cpu: 5300, gc_ms: 480, bootsnap: false) }, [5600.0] * 5 + [6400.0], nil, %w[bootsnap_off cpu_bound_boot]],
  }.freeze

  CAL.each do |name, (recs, init_ms, reports, want)|
    define_method("test_calibration_0_2_#{name.downcase.tr(" ", "_")}") do
      got = hints(recs.(self), init_ms: init_ms, init_reports: reports == :timeout ? timeout : nil)
      assert_equal want.sort, got.map(&:id).sort, name
      assert_equal "possible", got.find { _1.id == "cpu_bound_boot" }.level if want.include?("cpu_bound_boot")
    end
  end

  # --- calibration: per-cell medians of §1.1 (0.3.1 lines) must give the second §3.1 table (0.4 target).
  # Numbers are the published medians, rounded; no IDs. {id => level}.

  def cell31(n, share, rss_mb:, gc_share:, **kw)
    recs = shared(n, share, **kw)
    recs.each { |r| r["proc"]["rss_kb"] = rss_mb * 1024; r["proc"]["gc_time_ms"] = (r["proc"]["cpu_ms"] * gc_share).round }
  end

  CAL31 = {
    "CR gen1 minimal" => [-> { _1.cell31(6, 0.75, ready: 8000, rss_mb: 144, gc_share: 0.06, limits: _1.cr(quota: 2)) }, nil,
                          { "cpu_bound_boot" => "possible" }, /already uses about one core.*gVisor.*startup CPU boost/],
    "CR gen2 minimal" => [-> { _1.cell31(5, 0.29, ready: 7600, rss_mb: 89, gc_share: 0.09, limits: _1.cr(quota: 1.97, sandbox: nil), rejected: true) +
                               _1.cell31(1, 0.77, ready: 7600, rss_mb: 89, gc_share: 0.09, limits: _1.cr(quota: 1.97, sandbox: nil), rejected: true) }, nil,
                          { "wait_dominated_boot" => "likely", "prestarted_process" => "note" }, nil],
    "CR gen1 Redmine" => [-> { _1.cell31(6, 0.59, ready: 14_600, rss_mb: 280, gc_share: 0.06, limits: _1.cr(quota: 2), bootsnap: false) }, nil,
                          { "bootsnap_off" => "likely" }, nil],
    "Lambda Redmine 1024" => [-> { _1.cell31(5, 0.92, platform: :lambda, memory_mb: 1024, ready: 5800, rss_mb: 230, gc_share: 0.09, bootsnap: false) },
                              [7500.0, 5900.0, 5700.0, 4500.0, 5800.0, 5800.0],
                              { "cpu_bound_boot" => "possible", "bootsnap_off" => "likely", "lambda_init_near_limit" => "likely" }, /more memory is unlikely to shorten Init/],
    "Lambda Redmine 2048" => [-> { _1.cell31(6, 0.94, platform: :lambda, memory_mb: 2048, ready: 5700, rss_mb: 229, gc_share: 0.09, bootsnap: false) },
                              [6500.0, 5700.0, 5800.0, 5500.0, 5800.0, 4500.0],
                              { "cpu_bound_boot" => "possible", "bootsnap_off" => "likely" }, nil],
  }.freeze

  CAL31.each do |name, (recs, init_ms, want, cpu_text)|
    define_method("test_calibration_0_3_1_#{name.downcase.tr(" ", "_")}") do
      got = hints(recs.(self), init_ms: init_ms)
      assert_equal want, got.to_h { [_1.id, _1.level] }, name
      assert_match(cpu_text, got.find { _1.id == "cpu_bound_boot" }.message, name) if cpu_text
    end
  end

  # --- wait_dominated_boot split on lines shaped like measured ones (synthetic numbers, no real data)

  # wall = load -> first response; cpu and run-queue delta in ms
  def split_line(wall, cpu, runq, platform: :cloud_run, limits: cr(quota: 2.086, sandbox: nil), counters: {})
    r = line(platform: platform, limits: limits, ready: wall + 200 - 400 + 200, cpu_at_load: 100, cpu: 100 + cpu, bootsnap: true, bootsnap_cache: true,
             runq_wait: runq && runq + 2, runq_wait_at_load: runq && 2)
    counters.each { |k, v| r["proc"][k] = v }
    r
  end

  def test_split_gen2_shape_is_not_cpu
    recs = [6200, 6400, 6500, 6700].zip([1550, 1600, 1650, 1700], [1, 2, 1, 2]).map { split_line(*_1) } +
           [split_line(1600, 1350, 1), split_line(1600, 1480, 2)]
    h = hint(recs, "wait_dominated_boot")
    assert_equal "likely", h.level
    assert_equal ["not_cpu", 4], h.evidence.values_at("wait_kind", "wait_lines")
    assert_operator h.evidence["runq_share_of_non_cpu_p50"], :<, 0.01
    assert_match(/It was not waiting for a CPU/, h.message)
    refute_includes ids(recs), "cpu_bound_boot"
  end

  def test_split_lambda_shape_is_cpu_bound
    recs = [[4950, 4500, 75], [5000, 4550, 110], [4900, 4450, 144], [5050, 4600, 90]].map { split_line(*_1, platform: :lambda, limits: LAMBDA) }
    assert_includes ids(recs), "cpu_bound_boot"
    refute_includes ids(recs), "wait_dominated_boot"
  end

  # gVisor: the run-queue fields are null, so the kind is unknown and the 0.4.2 wording stays. majflt,
  # io_read_bytes and steal are left out (gVisor reports 0 for them); PSI would still show
  def test_split_gvisor_without_runq_is_unknown
    c = { "majflt" => 10, "majflt_at_load" => 4, "psi_io_some_ms" => 900, "psi_io_some_at_load_ms" => 100 }
    recs = Array.new(4) { split_line(6400, 1600, nil, limits: cr(quota: 2, sandbox: "gvisor"), counters: c) }
    h = hint(recs, "wait_dominated_boot")
    assert_equal "unknown", h.evidence["wait_kind"]
    assert_match(/More CPU is unlikely to help\. Likely causes: file IO .*or CPU throttled before the first request\./, h.message)
    assert_match(/Over the same span \(median\): system-wide IO stall \(PSI\) 800 ms\./, h.message)
    refute_match(/major page faults/, h.message)
    assert_match(/gVisor system-call work/, h.message)
    assert_equal [nil, 800], h.evidence.values_at("majflt_p50", "psi_io_some_ms_p50")
  end

  # As 0.4.3 lines from Cloud Run gen1 look: majflt, read_bytes and steal stay 0, PSI and runq are null
  def test_gvisor_zero_counters_are_not_shown
    c = { "majflt" => 0, "majflt_at_load" => 0, "io_read_bytes" => 0, "io_read_bytes_at_load" => 0,
          "steal_ms" => 0, "steal_at_load_ms" => 0 }
    recs = Array.new(4) { split_line(7300, 1800, nil, limits: cr(quota: 2, sandbox: "gvisor"), counters: c) }
    h = hint(recs, "wait_dominated_boot")
    refute_match(/Over the same span|major page faults/, h.message)
    assert_equal [nil, nil, nil], h.evidence.values_at("majflt_p50", "io_read_bytes_p50", "steal_ms_p50")
    # the same zeros outside gVisor are real readings
    recs = Array.new(4) { split_line(7300, 1800, nil, limits: cr(quota: 2, sandbox: nil), counters: c) }
    assert_match(/Over the same span \(median\): 0 major page faults\./, hint(recs, "wait_dominated_boot").message)
  end

  # proc_delta: nil when either reading is missing or the counter went backwards (reset, wrap)
  def test_proc_delta
    ctx = H::Context.new([])
    d = ->(at_load, at_emit) { ctx.proc_delta({ "proc" => { "majflt" => at_emit, "majflt_at_load" => at_load } }, "majflt") }
    assert_equal [40, 0, nil, nil, nil], [d.(10, 50), d.(7, 7), d.(50, 10), d.(nil, 5), d.(5, nil)]
    r = { "proc" => { "psi_io_some_ms" => 900.0, "psi_io_some_at_load_ms" => 100.0, "steal_ms" => 5, "steal_at_load_ms" => 9 } }
    assert_equal [800.0, nil], [ctx.proc_delta(r, "psi_io_some_ms"), ctx.proc_delta(r, "steal_ms")]
  end
end
