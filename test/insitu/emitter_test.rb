# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/emitter"
# Load the entry with insitu forced off: it must define only enabled? and start nothing.
begin
  old = ENV["HAYAOKI_INSITU"]
  ENV["HAYAOKI_INSITU"] = "0"
  require "hayaoki/insitu"
ensure
  ENV["HAYAOKI_INSITU"] = old
end

class InsituEmitterTest < Minitest::Test
  I = Hayaoki::Insitu
  FACTS = {"cpu_ms" => 1}.freeze

  # marks are relative to load_ms = 1000.0 (raw clock ms)
  def state(marks = {}, env: {}, **kw)
    st = I::State.new(env: env, load_ms: 1000.0, id: "abcd1234", **kw)
    marks.each { |k, v| st.mark(k, 1000.0 + v) }
    st
  end

  def full_marks
    {bundler_require_start: 200, bundler_require_end: 800, initialize_start: 870, initialize_end: 1900,
     first_probe: 1920, first_request_start: 1930, first_response_end: 2190}
  end

  def test_gating
    assert I.enabled?("HAYAOKI_INSITU" => "1")
    refute I.enabled?("HAYAOKI_INSITU" => "0", "RAILS_ENV" => "production")
    assert I.enabled?("RAILS_ENV" => "production")
    assert I.enabled?("RAILS_ENV" => "", "RACK_ENV" => "production")
    refute I.enabled?("RAILS_ENV" => "staging", "RACK_ENV" => "production")
    refute I.enabled?({})
    refute I.enabled?("HAYAOKI_INSITU" => "off", "RACK_ENV" => "production")
  end

  def test_require_when_off_is_a_noop
    refute defined?(Hayaoki::Insitu::STARTED)
    refute defined?(Hayaoki::Insitu::LOAD_MS)
    assert_nil I.state
  end

  # Start read once at load (State#start_ms) and used by default: a preloaded worker keeps
  # the master's start, so boot phases stay on the same origin.
  def test_build_uses_state_start_ms_by_default
    st = state(full_marks, start_ms: 820.0)
    h = I::Emitter.build(st, "ok", facts: FACTS, env: {})
    assert_equal 180, h["marks_ms"]["loaded"]
    assert_equal 180, h["phases_ms"]["pre_load"]
    assert_equal 1030, h["phases_ms"]["initialize"]
    assert_equal "proc_stat", h["start_source"]
  end

  # Cloud Run gen1 (0.2.0): /proc starttime 2 h before the load mark. Not a boot: fall back to the
  # load origin and keep the rejected gap in the line.
  def test_implausible_process_start_falls_back_to_load
    st = state(full_marks, start_ms: 1000.0 - 7_209_434)
    h = I::Emitter.build(st, "ok", facts: FACTS, env: {})
    assert_equal "load", h["start_source"]
    assert_nil h["start_at"]
    assert_equal({"reason" => "pre_load_over_limit", "pre_load_ms" => 7_209_434}, h["start_rejected"])
    assert_nil h["phases_ms"]["pre_load"]
    assert_equal 2190, h["phases_ms"]["to_first_response"]
    assert_equal 1030, h["phases_ms"]["initialize"]
    assert_equal "hayaoki cold start: ready 1920ms, first response 2190ms", h["message"]
    # a start after the load mark is rejected too
    h = I::Emitter.build(state(full_marks), "ok", start_ms: 1500.0, facts: FACTS, env: {})
    assert_equal({"reason" => "start_after_load", "pre_load_ms" => -500}, h["start_rejected"])
    assert_equal "load", h["start_source"]
  end

  def test_plausible_process_start_has_no_rejection_field
    max = I::Emitter::MAX_PRE_LOAD_MS
    h = I::Emitter.build(state(full_marks), "ok", start_ms: 1000.0 - max, facts: FACTS, env: {})
    assert_equal "proc_stat", h["start_source"]
    assert_equal max, h["phases_ms"]["pre_load"]
    refute h.key?("start_rejected")
  end

  def test_incomplete_message
    h = I::Emitter.build(state({initialize_end: 500, first_request_start: 600}), "incomplete", start_ms: nil, facts: FACTS, env: {})
    assert_equal "incomplete", h["status"]
    assert_match(/first response not finished/, h["message"])
    assert_nil h["phases_ms"]["to_first_response"]
  end

  def test_build_with_process_start
    st = state
    st.eager_span(Module.new.tap { |m| def m.name = "TZInfo" }) { nil }
    full_marks.each { |k, v| st.mark(k, 1000.0 + v) }
    h = I::Emitter.build(st, "ok", start_ms: 820.0, facts: FACTS, env: {"K_SERVICE" => "svc"})
    assert_equal "cold_start", h["hayaoki"]
    assert_equal "proc_stat", h["start_source"]
    m = h["marks_ms"]
    assert_equal 180, m["loaded"]
    assert_equal 2370, m["first_response_end"]
    ph = h["phases_ms"]
    assert_equal 180, ph["pre_load"]
    assert_equal 200, ph["pre_bundler"]
    assert_equal 600, ph["bundler_require"]
    assert_equal 70, ph["app_config"]
    assert_equal 1030, ph["initialize"]
    assert_equal 2100, ph["to_ready"]
    assert_equal "probe", h["ready_source"]
    assert_equal 10, ph["idle"]
    assert_equal 260, ph["first_request"]
    assert_equal 2370, ph["to_first_response"]
    assert_equal "TZInfo", h["eager_top"][0][0]
    assert_equal "hayaoki cold start: ready 2100ms, first response 2370ms", h["message"]
    assert_equal({"kind" => "cloud_run", "service" => "svc"}, h["platform"])
    assert_equal FACTS, h["proc"]
    refute h["worker"]
    assert_match(/\A\d{4}-\d\d-\d\dT/, h["start_at"])
  end

  def test_build_without_process_start_uses_load_origin
    h = I::Emitter.build(state(full_marks), "ok", start_ms: nil, facts: FACTS, env: {})
    assert_equal "load", h["start_source"]
    assert_nil h["start_at"]
    assert_equal 0, h["marks_ms"]["loaded"]
    assert_nil h["phases_ms"]["pre_load"]
    assert_nil h["phases_ms"]["eager_load"]
    assert_equal 200, h["phases_ms"]["pre_bundler"]
  end

  def test_ready_falls_back_to_initialize_end
    marks = full_marks.reject { |k, _| k == :first_probe }
    h = I::Emitter.build(state(marks), "ok", start_ms: nil, facts: FACTS, env: {})
    assert_equal "initialize", h["ready_source"]
    assert_equal 1900, h["phases_ms"]["to_ready"]
    # a probe that arrives after the first request is not "ready"
    h = I::Emitter.build(state(marks.merge(first_probe: 3000)), "ok", start_ms: nil, facts: FACTS, env: {})
    assert_equal "initialize", h["ready_source"]
  end

  def test_null_marks_give_null_phases
    h = I::Emitter.build(state({}), "no_request", start_ms: nil, facts: FACTS, env: {})
    assert(h["phases_ms"].values.all?(&:nil?))
    assert_nil h["ready_source"]
    assert_equal "hayaoki cold start: ready ?ms, no request", h["message"]
  end

  def test_boot_error
    st = state({initialize_start: 10})
    st.boot_error = "NameError"
    h = I::Emitter.build(st, "boot_error", start_ms: nil, facts: FACTS, env: {})
    assert_equal "ERROR", h["severity"]
    assert_equal "NameError", h["error_class"]
  end

  def test_eager_span_counts_outermost_only
    st = state
    st.eager_span(Object) { st.eager_span(String) { sleep 0.002 } }
    assert_equal ["Object"], st.eager_by.keys
    assert_operator st.eager_ms, :>=, 2
    st.mark(:initialize_end)
    st.eager_span(Integer) { nil }
    refute st.eager_by.key?("Integer")
  end

  def test_emit_once_to_file_with_real_facts
    Dir.mktmpdir do |dir|
      out = File.join(dir, "log")
      st = state(full_marks, env: {"HAYAOKI_INSITU_OUT" => out})
      line = I::Emitter.emit(st, "ok")
      refute_nil line
      assert_nil I::Emitter.emit(st, "no_request")
      lines = File.readlines(out)
      assert_equal 1, lines.size
      data = JSON.parse(lines[0])
      assert_equal "ok", data["status"]
      assert_operator lines[0].bytesize, :<=, 4096
      %w[cpu_ms gc_count gc_time_ms features i18n_loaded rss_kb uptime_ms pid1_age_ms].each { assert data["proc"].key?(_1), _1 }
      %w[ruby rails hayaoki yjit env bootsnap bootsnap_cache eager_load entry].each { assert data["runtime"].key?(_1), _1 }
    end
  end

  def test_emit_failure_is_silent_with_one_warning
    st = state(env: {"HAYAOKI_INSITU_OUT" => "/nonexistent-dir/x/log"})
    I.instance_variable_set(:@warned, false)
    _, err = capture_io { assert_nil I::Emitter.emit(st, "ok") }
    assert_match(/\[hayaoki insitu\]/, err)
    _, err = capture_io { I.warn_once("again", RuntimeError.new) }
    assert_empty err
  end
end

class InsituEmitterCpuFieldsTest < Minitest::Test
  I = Hayaoki::Insitu
  FACTS = {"cpu_ms" => 1}.freeze
  LIMITS = {"cgroup" => "v2", "cpu_quota" => 2.0, "nproc" => 2, "sandbox" => "gvisor"}.freeze

  # marks at wall t (ms after load), cpu at c (ms of CPU)
  def state(marks, load_cpu: 100.0, limits: LIMITS)
    st = I::State.new(env: {}, load_ms: 1000.0, load_cpu_ms: load_cpu, id: "abcd1234", start_ms: nil, limits: limits)
    marks.each do |k, (t, c)|
      st.marks[k] = 1000.0 + t
      st.cpu_marks[k] = c
    end
    st
  end

  FULL = {bundler_require_start: [200, 150.0], bundler_require_end: [800, 650.0], initialize_start: [870, 700.0],
          initialize_end: [1900, 1700.0], first_probe: [1920, 1710.0], first_request_start: [1930, 1720.0],
          first_response_end: [2190, 1900.0]}.freeze

  def test_cpu_phases_and_limits
    h = I::Emitter.build(state(FULL), "ok", facts: {"cpu_ms" => 1, "cpu_at_load_ms" => 100}, env: {})
    assert_equal({"bundler_require" => 500, "initialize" => 1000, "load_to_ready" => 1610, "load_to_first_response" => 1800},
                 h["phases_cpu_ms"])
    assert_equal %w[cgroup cpu_quota nproc mem_max_mb sandbox], h["limits"].keys
    assert_equal "v2", h["limits"]["cgroup"]
    assert_equal 2.0, h["limits"]["cpu_quota"]
    assert_equal "gvisor", h["limits"]["sandbox"]
  end

  def test_cpu_at_load_in_proc
    h = I::Emitter.build(state(FULL, load_cpu: 100.4), "ok", env: {})
    assert_equal 100, h["proc"]["cpu_at_load_ms"]
  end

  def test_ready_from_initialize_when_no_probe
    marks = FULL.reject { |k, _| k == :first_probe }
    h = I::Emitter.build(state(marks), "ok", facts: FACTS, env: {})
    assert_equal 1600, h["phases_cpu_ms"]["load_to_ready"]
  end

  def test_nil_safe_without_marks_or_readings
    h = I::Emitter.build(state({}, load_cpu: nil, limits: {}), "no_request", facts: FACTS, env: {})
    assert_equal({"bundler_require" => nil, "initialize" => nil, "load_to_ready" => nil, "load_to_first_response" => nil},
                 h["phases_cpu_ms"])
    assert_nil h["limits"]["cgroup"]
    assert_nil h["limits"]["cpu_quota"]
    h = I::Emitter.build(state({initialize_end: [500, nil]}, load_cpu: nil), "incomplete", facts: FACTS, env: {})
    assert_nil h["phases_cpu_ms"]["load_to_ready"]
  end

  def test_forked_child_has_no_cross_process_cpu_span
    st = state(FULL)
    st.forked_in_child!
    st.mark(:first_response_end)
    h = I::Emitter.build(st, "ok", facts: FACTS, env: {})
    assert_nil h["phases_cpu_ms"]["load_to_first_response"]
    assert_equal 500, h["phases_cpu_ms"]["bundler_require"]
  end

  def test_forked_child_cpu_at_load_nil_and_probe_ready_nil
    st = state(FULL.reject { |k, _| %i[first_probe first_response_end].include?(k) })
    st.forked_in_child!
    st.probe_hit!
    h = I::Emitter.build(st, "ok", env: {})
    assert_nil h["proc"]["cpu_at_load_ms"]
    assert_equal "probe", h["ready_source"]
    assert_nil h["phases_cpu_ms"]["load_to_ready"]
  end

  def test_state_mark_records_cpu_once
    st = I::State.new(env: {}, load_ms: 1000.0, limits: {})
    st.mark(:initialize_start, 1100.0)
    c = st.cpu_marks[:initialize_start]
    assert_kind_of Float, c
    st.mark(:initialize_start, 1200.0)
    assert_equal c, st.cpu_marks[:initialize_start]
    assert_kind_of Float, st.cpu_marks[:loaded]
  end
end
