# frozen_string_literal: true

require "test_helper"
require "hayaoki/cold_start_report/runner"

class HintsTest < Minitest::Test
  H = Hayaoki::ColdStartReport::Hints

  # Synthetic cold_start line with placeholder values only (service svc, revision svc-00001-abc, function fn).
  def line(platform: :lambda, memory_mb: 1024, ready: 6800, cpu: 5400, gc_ms: 500, gc_count: 20, bootsnap: false,
           bootsnap_cache: nil, pre_load: 400, rejected: false, status: "ok", revision: "svc-00001-abc", init_type: "on-demand")
    plat = if platform == :lambda
             { "kind" => "lambda", "function" => "fn", "memory_mb" => memory_mb, "init_type" => init_type }
           else
             { "kind" => "cloud_run", "service" => "svc", "revision" => revision }
           end
    rec = { "hayaoki" => "cold_start", "v" => 1, "status" => status, "platform" => plat,
            "runtime" => { "bootsnap" => bootsnap, "bootsnap_cache" => bootsnap_cache },
            "phases_ms" => { "pre_load" => pre_load, "to_ready" => ready, "to_first_response" => ready + 200 },
            "proc" => { "cpu_ms" => cpu, "gc_time_ms" => gc_ms, "gc_count" => gc_count, "rss_kb" => 200_000 } }
    rec["start_rejected"] = { "reason" => "pre_load_over_limit", "pre_load_ms" => 3_600_000 } if rejected
    rec
  end

  def lines(n, **kw) = Array.new(n) { line(**kw) }

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

  # --- calibration: per-cell medians of resource-hints.md §1 must give the 0.3 hints of §3.1

  def cell(n, implausible: 0, **kw) = lines(n - implausible, **kw) + lines(implausible, pre_load: 3_000_000, **kw)

  CAL = {
    "CR gen1 minimal" => [-> { _1.cell(6, implausible: 1, platform: :cloud_run, ready: 4900, cpu: 3600, gc_ms: 360, bootsnap: true, bootsnap_cache: true) }, nil, nil, []],
    "CR gen2 minimal" => [-> { _1.cell(6, implausible: 6, platform: :cloud_run, ready: 6500, cpu: 3800, gc_ms: 380, bootsnap: true, bootsnap_cache: true) }, nil, nil, %w[prestarted_process]],
    "CR gen1 Redmine" => [-> { _1.cell(6, platform: :cloud_run, ready: 20_300, cpu: 12_000, gc_ms: 600, bootsnap: false) }, nil, nil, %w[bootsnap_off]],
    "Lambda minimal 1024" => [-> { _1.cell(6, memory_mb: 1024, ready: 1800, cpu: 1500, gc_ms: 210, bootsnap: true, bootsnap_cache: true) }, [1800.0] * 5 + [3100.0], nil, []],
    "Lambda minimal 2048" => [-> { _1.cell(6, memory_mb: 2048, ready: 1900, cpu: 1600, gc_ms: 225, bootsnap: true, bootsnap_cache: true) }, [1900.0] * 5 + [2100.0], nil, []],
    "Lambda Redmine 1024" => [-> { _1.cell(4, memory_mb: 1024, ready: 6800, cpu: 5300, gc_ms: 480, bootsnap: false) + _1.lines(1, ready: 9300, cpu: 5400, gc_ms: 480, bootsnap: false) },
                              [6000.0, 6100.0, 6800.0, 7000.0, 9300.0, 10_000.0], :timeout, %w[bootsnap_off lambda_init_near_limit]],
    "Lambda Redmine 2048" => [-> { _1.cell(6, memory_mb: 2048, ready: 5600, cpu: 5300, gc_ms: 480, bootsnap: false) }, [5600.0] * 5 + [6400.0], nil, %w[bootsnap_off]],
  }.freeze

  CAL.each do |name, (recs, init_ms, reports, want)|
    define_method("test_calibration_#{name.downcase.tr(" ", "_")}") do
      got = ids(recs.(self), init_ms: init_ms, init_reports: reports == :timeout ? timeout : nil)
      assert_equal want.sort, got.sort, name
    end
  end
end
