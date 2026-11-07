# frozen_string_literal: true

require "test_helper"

# spike/04_probe/edge/run_edge.sh の移植 (+ SIGTERM)
class ProbeEdgeTest < Minitest::Test
  include ProbeHelper

  def test_thread_span_is_a_separate_root
    r = run_probe('t = Thread.new { require "./t_slow" }; require "./t_main"; t.join')
    rep = r.report
    assert_equal "ok", rep["status"]
    slow = rep.feature("t_slow.rb").first
    main = rep.feature("t_main.rb").first
    leaf = rep.feature("t_leaf.rb").first
    assert_equal(-1, slow.parent)
    refute_equal 0, slow.tid
    assert_equal 0, main.tid
    assert_equal main.idx, leaf.parent, "main thread nesting is not disturbed by the thread span"
    assert_equal 0, leaf.tid
  end

  def test_span_raised_inside_rescue_is_kept_as_raised
    r = run_probe('begin; require "./t_raise"; rescue => e; end; require "./t_leaf"')
    rep = r.report
    assert_equal "ok", rep["status"]
    raised = rep.of_kind(0).find { |s| s.name == "./t_raise" }
    assert_predicate raised, :raised?
    assert_equal "raised", raised.res
    leaf = rep.feature("t_leaf.rb").first
    assert_equal(-1, leaf.parent, "stack must be popped after the exception")
  end

  def test_boot_failure_returns_partial_result_with_status_error
    r = run_probe('require "./t_main"; require "./t_raise"')
    refute_predicate r.status, :success?
    rep = r.report
    assert_equal "error", rep["status"]
    assert_equal "RuntimeError", rep["error"]["class"]
    assert_equal "boom", rep["error"]["message"]
    assert_operator rep["error"]["backtrace"].size, :<=, 20
    assert_equal 1, rep.feature("t_main.rb").size
    assert_predicate rep.of_kind(0).find { |s| s.name == "./t_raise" }, :raised?
    refute_nil rep["boot_end_us"]
  end

  def test_exit_1_is_error_and_exit_0_is_ok
    assert_equal "error", run_probe("require './t_leaf'; exit 1").report["status"]
    assert_equal "ok", run_probe("require './t_leaf'; exit 0").report["status"]
  end

  def test_works_with_disable_gems
    r = run_probe('require "./t_main"', ruby_args: ["--disable-gems"])
    rep = r.report
    assert_equal "ok", rep["status"]
    assert_equal 1, rep.feature("t_main.rb").size
    assert_equal 1, rep.feature("t_leaf.rb").size
  end

  def test_fork_child_does_not_write
    r = run_probe('require "./t_main"; Process.wait(fork { require "./t_slow" })')
    rep = r.report
    assert_equal "ok", rep["status"]
    assert_empty rep.feature("t_slow.rb"), "result must be the parent's"
    assert_equal 1, rep.feature("t_main.rb").size
  end

  def test_fork_child_exiting_after_parent_result_does_not_overwrite
    code = 'require "./t_main"; pid = fork { require "./t_slow"; exit 3 }; Process.wait(pid)'
    rep = run_probe(code).report
    assert_empty rep.feature("t_slow.rb")
    assert_equal "ok", rep["status"]
  end

  def test_loading_probe_twice_is_harmless
    r = run_probe('require "./t_leaf"', probe_args: [PROBE, PROBE])
    assert_equal 1, r.report.feature("t_leaf.rb").size
    r = run_probe(%(load #{PROBE.dump}; load #{PROBE.dump}; require "./t_leaf"))
    rep = r.report
    assert_equal "ok", rep["status"]
    assert_equal 1, rep.feature("t_leaf.rb").size
    assert_empty r.err
  end

  def test_exit_bang_produces_no_output
    r = run_probe('require "./t_main"; exit! 0')
    assert_nil r.data
  end

  def test_sigterm_returns_error_and_marks_where_it_stopped
    Dir.mktmpdir("hayate-sigterm") do |dir|
      ready = File.join(dir, "ready")
      out = File.join(dir, "out.json")
      env = CLEAN_ENV.merge("HAYATE_PROBE_OUT" => out, "READY_FILE" => ready)
      pid = Process.spawn(env, RbConfig.ruby, "-r#{PROBE}", "-e", 'require "./t_forever"',
                          chdir: File.join(FIXTURES, "edge"), out: File::NULL, err: File::NULL)
      60.times { break if File.exist?(ready); sleep 0.1 }
      assert File.exist?(ready), "child did not start"
      Process.kill("TERM", pid)
      Process.wait(pid)
      rep = ProbeReport.new(JSON.parse(File.read(out)))
      assert_equal "error", rep["status"]
      assert_equal "SignalException", rep["error"]["class"]
      assert_predicate rep.of_kind(0).find { |s| s.name == "./t_forever" }, :raised?
    end
  end
end
