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
           cpu_at_load: nil, limits: nil, rss_kb: 200_000, worker: false)
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
            "proc" => { "cpu_ms" => cpu, "cpu_at_load_ms" => cpu_at_load, "gc_time_ms" => gc_ms, "gc_count" => gc_count, "rss_kb" => rss_kb } }
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
                   "quota_source" => "cgroup", "from_load_lines" => 3 }, h.evidence)
    assert_match(/on CPU 75% of the time from load to first response \(median of 3; CPU 5.1 s of 6.8 s; quota 2.0 vCPU\)/, h.message)
    assert_match(/already uses about one core/, h.message)
    assert_match(/gVisor \(gen1\) sandbox work shares the same CPU quota/, h.message)
    assert_match(/If startup CPU boost is not on/, h.message)
    refute_match(/quota is not visible/, h.message)
    assert_equal %w[startup_cpu_boost cpu_allocation], h.cannot_see
    refute_match(/gVisor/, hint(shared(3, 0.75, limits: cr(sandbox: nil)), "cpu_bound_boot").message)
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
end
