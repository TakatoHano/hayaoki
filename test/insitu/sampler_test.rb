# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/hooks"
require "hayaoki/insitu/emitter"
require "hayaoki/insitu/sampler"

# Main-thread state sampler (resource-hints.md §2.2.3). No test reads the real /proc: the pure parts
# take a clock and a state source, and the fork tests point the child at a file they write.
class InsituSamplerTest < Minitest::Test
  I = Hayaoki::Insitu
  S = I::Sampler
  R = "R".ord
  D = "D".ord
  SL = "S".ord

  # Answers pread like an open stat file
  class FakeStat
    def initialize(text = nil, error: nil) = (@text, @error = text, error)

    def pread(_len, _offset, buf)
      raise @error if @error
      buf.replace(@text)
    end
  end

  def stat_line(state, comm: "ruby") = "42 (#{comm}) #{state} 1 42 42 0 -1 4194560 100 0 0 0 150 30 0 0 20 0 5 0 987654\n"

  def tally(samples, **kw)
    t = S::Tally.new(**kw)
    samples.each { |at, st| t.add(at, st) }
    t
  end

  # --- Tally

  def test_tally_credits_each_step_to_the_state_seen_at_its_end
    t = tally([[0, R], [10, R], [20, D], [30, D], [41, SL], [50, nil], [60, "T".ord]])
    assert_equal 7, t.samples
    assert_equal [10.0, 20.0, 11.0, 19.0], [t.r, t.d, t.s, t.other]
    assert_equal [0, 0.0, 0.0], [t.gaps, t.gap, t.gap_max]
    assert_equal 60.0, t.wall
    assert_equal t.wall, t.r + t.d + t.s + t.other + t.gap
  end

  def test_tally_gap_is_a_step_over_five_intervals_less_one_interval
    # 50 ms is still a late sample; 51 ms is a gap of 41 ms and one interval for the state
    assert_equal [0, 50.0], tally([[0, R], [50, D]]).then { [_1.gaps, _1.d] }
    t = tally([[0, R], [51, D], [61, D], [1061, SL]])
    assert_equal [2, 41.0 + 990.0, 990.0], [t.gaps, t.gap, t.gap_max]
    assert_equal [20.0, 10.0, 0.0], [t.d, t.s, t.r]
    assert_equal 1061.0, t.r + t.d + t.s + t.other + t.gap
  end

  def test_tally_interval_and_factor_and_edge_cases
    t = tally([[0, R], [30, R], [100, R]], interval_ms: 20, gap_factor: 2)
    assert_equal [1, 50.0, 50.0], [t.gaps, t.gap, t.r]
    assert_equal 0.0, S::Tally.new.wall
    assert_equal 0.0, tally([[5, R]]).wall
    # a clock that steps back adds nothing
    assert_equal [0.0, 0], tally([[10, R], [5, R]]).then { [_1.r, _1.gaps] }
  end

  # --- read_state

  def test_read_state
    buf = +""
    assert_equal R, S.read_state(FakeStat.new(stat_line("R")), buf)
    assert_equal D, S.read_state(FakeStat.new(stat_line("D", comm: "my (weird) proc")), buf)
    assert_equal SL, S.read_state(FakeStat.new("42 (ruby) S"), buf)
    %w[Z X x].each { assert_equal :gone, S.read_state(FakeStat.new(stat_line(_1)), buf), _1 }
    ["", "garbage", "42 (ruby)", "42 (ruby) "].each { assert_nil S.read_state(FakeStat.new(_1), buf), _1.inspect }
  end

  def test_read_state_errors
    buf = +""
    assert_equal :gone, S.read_state(FakeStat.new(error: Errno::ESRCH), buf)
    assert_equal :gone, S.read_state(FakeStat.new(error: Errno::ENOENT), buf)
    assert_nil S.read_state(FakeStat.new(error: Errno::EACCES), buf)
    assert_nil S.read_state(FakeStat.new(error: EOFError), buf)
  end

  # --- run_loop

  def loop_with(states, waits, times, **kw)
    t = S::Tally.new
    out = S.run_loop(t, clock: -> { times.shift }, read_state: -> { states.shift }, wait: -> { waits.shift }, **kw)
    [out, t]
  end

  def test_run_loop_stops_and_reports_when_the_parent_closes_the_pipe
    out, t = loop_with([R, D, D, SL], %i[tick tick stop], [0, 10, 20, 25])
    assert_equal [true, false], out
    assert_equal [4, 20.0, 5.0], [t.samples, t.d, t.s]
  end

  def test_run_loop_truncates_at_the_limit
    out, t = loop_with([R, R, R, R], %i[tick tick tick], [0, 10, 20, 30], max_ms: 20)
    assert_equal [true, true], out
    assert_equal 3, t.samples
  end

  def test_run_loop_ends_without_a_report_when_the_parent_is_gone
    assert_equal [false, false], loop_with([:gone], [], [0])[0]
    out, t = loop_with([R, R, :gone], %i[tick tick], [0, 10, 20])
    assert_equal [false, false], out
    assert_equal 2, t.samples
  end

  # --- wire format and line fields

  def test_encode_decode_round_trip
    v = { "samples" => 498, "wall" => 5_210_400.4, "r" => 1_540_000.0, "d" => 3_400_000.0, "s" => 120_400.0, "other" => 0.0,
          "gaps" => 2, "gap" => 150_000.0, "gap_max" => 90_000.0, "trunc" => 0, "suspend" => nil, "cpu" => 28_300.0, "runq" => nil, "majflt" => 0 }
    text = S.encode(v)
    assert_equal "hs1 498 5210400 1540000 3400000 120400 0 2 150000 90000 0 - 28300 - 0\n", text
    w = S.decode(text)
    assert_equal S::WIRE_KEYS, w.keys
    assert_equal [498, 5_210_400, nil, 0], w.values_at("samples", "wall", "runq", "majflt")
  end

  def test_decode_rejects_anything_else
    [nil, "", "hs1", "hs1 1 2 3", "hs2 #{(["1"] * 14).join(" ")}", "hs1 #{(["x"] * 14).join(" ")}", "hs1 #{(["1"] * 15).join(" ")}"].each do
      assert_nil S.decode(_1), _1.inspect
    end
  end

  def test_fields
    w = S.decode("hs1 498 5210400 1540000 3400000 120400 0 2 150000 90000 1 0 28300 3400 0\n")
    f = S.fields(w, till: "initialize_end", interval_ms: 10, fork_us: 812.6, collect_us: 420.2)
    assert_equal %w[status until interval_ms wall_ms samples r_ms d_ms s_ms other_ms gaps gap_ms gap_max_ms truncated suspend_ms
                    sampler_cpu_ms sampler_runq_wait_ms sampler_majflt fork_us collect_us], f.keys
    assert_equal ["ok", "initialize_end", 10, 5210, 498, 1540, 3400, 120, 0, 2, 150, 90, true, 0, 28, 3, 0, 813, 420], f.values
    g = S.fields(S.decode("hs1 3 20000 20000 0 0 0 0 0 0 0 - 100 - -\n"), till: "emit", interval_ms: 10, fork_us: nil, collect_us: nil)
    assert_equal [false, nil, nil, nil, nil], g.values_at("truncated", "suspend_ms", "sampler_runq_wait_ms", "sampler_majflt", "fork_us")
  end

  # --- the child process (a file the test writes stands in for the parent's stat file)

  def with_stat(state = "R")
    skip "no fork on this platform" unless Process.respond_to?(:fork)
    Dir.mktmpdir("hayaoki-sampler") do |dir|
      path = File.join(dir, "stat")
      File.write(path, stat_line(state))
      yield path
    end
  end

  def set_state(path, state) = File.open(path, "r+") { _1.write("42 (ruby) #{state}") }

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_gone(pid, limit: 2.0)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep 0.01 while alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < limit
    !alive?(pid)
  end

  def test_child_samples_reports_and_is_reaped
    with_stat("R") do |path|
      h = S.start(stat_path: path, threads: 1, timeout: 2 * TIMING_SLACK)
      assert h.running?
      sleep 0.1
      set_state(path, "D")
      sleep 0.2
      set_state(path, "S")
      sleep 0.1
      before = $?
      r = h.result("initialize_end")
      assert_equal ["ok", "initialize_end", 10, false], r.values_at("status", "until", "interval_ms", "truncated")
      assert_operator r["samples"], :>=, 5
      assert_operator r["wall_ms"], :>=, 350
      assert_operator r["d_ms"], :>=, 100
      assert_operator r["r_ms"], :>, 0
      assert_operator r["s_ms"], :>, 0
      assert_in_delta r["wall_ms"], r.values_at("r_ms", "d_ms", "s_ms", "other_ms", "gap_ms").sum, 3
      assert_kind_of Integer, r["fork_us"]
      assert_kind_of Integer, r["collect_us"]
      assert_kind_of Integer, r["sampler_cpu_ms"]
      refute h.running?
      assert_same r, h.result("emit") # the first call decides
      assert before.equal?($?), "the reap must not touch $?"
      refute alive?(h.pid), "child must be gone and reaped"
      assert_raises(Errno::ECHILD) { Process.wait(h.pid) }
    end
  end

  def test_child_exits_when_the_parent_goes_away
    with_stat do |path|
      rd, wr = IO.pipe
      parent = fork do
        rd.close
        wr.puts S.start(stat_path: path, threads: 1).pid
        wr.close
        exit!(0)
      end
      wr.close
      child = rd.gets.to_i
      Process.wait(parent)
      assert_operator child, :>, 0
      assert wait_gone(child), "sampler child outlived its parent"
    end
  end

  # The window ends at the limit, long before the parent asks; the line waits in the pipe.
  def test_child_stops_on_its_own_at_the_limit_and_the_result_is_still_read
    with_stat("D") do |path|
      h = S.start(stat_path: path, threads: 1, max_ms: 50, timeout: 2 * TIMING_SLACK)
      sleep 0.5 * TIMING_SLACK
      r = h.result
      assert_equal ["ok", "emit", true], r.values_at("status", "until", "truncated")
      assert_operator r["d_ms"], :>=, 40
      assert_operator r["wall_ms"], :<, 400 * TIMING_SLACK
      assert_raises(Errno::ECHILD) { Process.wait(h.pid) }
    end
  end

  def test_abort_ends_the_child_without_a_result
    with_stat do |path|
      h = S.start(stat_path: path, threads: 1)
      h.abort("forked")
      assert_equal({ "status" => "forked" }, h.result)
      assert wait_gone(h.pid)
      assert_raises(Errno::ECHILD) { Process.wait(h.pid) }
      assert_nil h.abort # again: nothing to do
    end
  end

  def test_child_that_does_not_answer_is_killed
    skip "no fork on this platform" unless Process.respond_to?(:fork)
    ctl = IO.pipe
    res = IO.pipe
    pid = fork do
      sleep 30
      exit!(0)
    end
    [ctl[0], res[1]].each(&:close)
    h = S::Handle.new(pid, ctl[1], res[0], timeout: 0.05)
    assert_equal({ "status" => "timeout" }, h.result)
    assert wait_gone(pid)
    assert_raises(Errno::ECHILD) { Process.wait(pid) }
  end

  def test_child_that_dies_without_a_line_gives_no_result
    skip "no fork on this platform" unless Process.respond_to?(:fork)
    ctl = IO.pipe
    res = IO.pipe
    pid = fork { exit!(0) }
    [ctl[0], res[1]].each(&:close)
    assert_equal({ "status" => "no_result" }, S::Handle.new(pid, ctl[1], res[0]).result)
  end

  def test_a_forked_copy_of_the_handle_leaves_the_child_alone
    with_stat do |path|
      h = S.start(stat_path: path, threads: 1, timeout: 2 * TIMING_SLACK)
      rd, wr = IO.pipe
      pid = fork do
        wr.puts [h.result.inspect, h.abort.inspect, h.running?.inspect].join(" ")
        exit!(0)
      end
      Process.wait(pid)
      wr.close
      assert_equal "nil nil false", rd.read.strip
      assert alive?(h.pid)
      assert_equal "ok", h.result["status"]
    end
  end

  def test_start_refuses_with_other_threads_or_an_unusable_stat_file
    assert_equal({ "status" => "threads" }, S.start(stat_path: "/nonexistent/stat", threads: 2).result)
    assert_equal({ "status" => "unsupported" }, S.start(stat_path: "/nonexistent/stat", threads: 1).result)
    Dir.mktmpdir("hayaoki-sampler") do |dir|
      path = File.join(dir, "stat")
      File.write(path, "garbage\n")
      h = S.start(stat_path: path, threads: 1)
      assert_equal({ "status" => "unsupported" }, h.result)
      assert_nil h.pid
      refute h.running?
    end
    refute I.sampler_fork
  end

  # --- wiring: env switch, hooks, emitter

  def test_enabled_only_by_the_env_var
    refute I.sampler_enabled?({})
    refute I.sampler_enabled?("HAYAOKI_INSITU_SAMPLER" => "0")
    refute I.sampler_enabled?("HAYAOKI_INSITU_SAMPLER" => "")
    %w[1 true on YES].each { assert I.sampler_enabled?("HAYAOKI_INSITU_SAMPLER" => _1), _1 }
  end

  class FakeSampler
    attr_reader :calls

    def initialize = @calls = []

    def result(till = "emit")
      @calls << [:result, till]
      @result ||= { "status" => "ok", "until" => till }
    end

    def abort(status = "aborted") = @calls << [:abort, status]
  end

  def with_state(st)
    saved = I.state
    I.instance_variable_set(:@state, st)
    yield st
  ensure
    I.instance_variable_set(:@state, saved)
  end

  def new_state(dir) = I::State.new(env: { "HAYAOKI_INSITU_OUT" => File.join(dir, "log") }, load_ms: I::Clock.now_ms, limits: {})

  def test_start_sampler_is_off_without_the_env_var_and_off_linux
    Dir.mktmpdir do |dir|
      with_state(new_state(dir)) do |st|
        I.start_sampler({}, linux: true)
        assert_nil st.sampler
        I.start_sampler({ "HAYAOKI_INSITU_SAMPLER" => "1" }, linux: false)
        assert_nil st.sampler
        assert_nil I::Emitter.build(st, "ok", facts: {}, env: {})["sampler"]
      end
    end
  end

  def test_after_initialize_ends_the_window_and_the_line_carries_it
    Dir.mktmpdir do |dir|
      with_state(new_state(dir)) do |st|
        st.sampler = FakeSampler.new
        I.after_initialize
        assert_equal [[:result, "initialize_end"]], st.sampler.calls
        h = I::Emitter.build(st, "ok", facts: {}, env: {})
        assert_equal({ "status" => "ok", "until" => "initialize_end" }, h["sampler"])
        assert_equal "sampler", h.keys.last
      end
    end
  end

  def test_without_initialize_the_emit_ends_the_window
    Dir.mktmpdir do |dir|
      st = new_state(dir)
      st.sampler = FakeSampler.new
      assert_equal "emit", I::Emitter.build(st, "boot_error", facts: {}, env: {})["sampler"]["until"]
    end
  end

  def test_forked_worker_line_has_no_sampler_data
    Dir.mktmpdir do |dir|
      st = new_state(dir)
      st.sampler = FakeSampler.new
      st.forked_in_child!
      assert_nil I::Emitter.build(st, "ok", facts: {}, env: {})["sampler"]
      assert_empty st.sampler.calls
    end
  end

  def test_a_raising_sampler_does_not_break_the_line
    Dir.mktmpdir do |dir|
      st = new_state(dir)
      st.sampler = Object.new.tap { |o| def o.result(*) = raise("boom") }
      assert_nil I::Emitter.build(st, "ok", facts: {}, env: {})["sampler"]
    end
  end

  def test_app_fork_aborts_the_sampler_and_at_exit_ends_it
    skip "no Process._fork" unless Process.respond_to?(:_fork)
    Process.singleton_class.prepend(I::Hooks::ForkHook)
    Dir.mktmpdir do |dir|
      with_state(new_state(dir)) do |st|
        st.sampler = FakeSampler.new
        pid = fork { exit!(0) }
        Process.wait(pid)
        assert_equal [[:abort, "forked"]], st.sampler.calls
        I.at_exit! # forked children: no line, but the sampler is still ended
        assert_equal [[:abort, "forked"], [:abort, "aborted"]], st.sampler.calls
      end
    end
  end

  # The sampler's own fork goes through Process._fork too; it must not count as an app fork.
  def test_sampler_fork_is_not_taken_for_an_app_fork
    skip "no Process._fork" unless Process.respond_to?(:_fork)
    Process.singleton_class.prepend(I::Hooks::ForkHook)
    with_stat do |path|
      Dir.mktmpdir do |dir|
        with_state(new_state(dir)) do |st|
          st.sampler = S.start(stat_path: path, threads: 1, timeout: 2 * TIMING_SLACK)
          refute st.forked_children?
          assert st.sampler.running?
          assert_equal "ok", st.sampler.result["status"]
        end
      end
    end
  end
end
