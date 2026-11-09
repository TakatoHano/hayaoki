# frozen_string_literal: true

require "test_helper"
require "stringio"
require "hayaoki/cli"
require "hayaoki/cold_start_report/runner"
require "hayaoki/cold_start_report/formatters/text"
require "hayaoki/cold_start_report/formatters/json"
require "hayaoki/insitu/emitter"

class ColdStartReportTest < Minitest::Test
  FX = File.join(FIXTURES, "cold_start")

  def fx(name) = File.read(File.join(FX, name))

  def build(*names, **kw) = Hayaoki::ColdStartReport.build(names.map { fx(_1) }, **kw)

  def run_cli(argv, stdin: "")
    out = StringIO.new
    err = StringIO.new
    code = Hayaoki::CLI.new(stdout: out, stderr: err, stdin: StringIO.new(stdin)).run(argv)
    [code, out.string, err.string]
  end

  def test_bare_lines
    s = build("bare.jsonl")["summary"]
    assert_equal 4, s["n"]
    assert_equal 1, s["proactive"]
    assert_equal 2000, s["ready_ms"]["p50"]
    assert_equal 2300, s["ready_ms"]["max"]
    assert_equal "issues#index", s["first_request"]["top_routes"][0]["route"]
    assert_equal 2, s["first_request"]["top_routes"][0]["count"]
    assert_equal "<gem:tzinfo>", s["first_request"]["new_by_group"][0]["group"]
    assert_equal 48, s["first_request"]["new_by_group"][0]["count"]
    assert_equal "TZInfo", s["eager_top"][0]["name"]
  end

  def test_cloud_logging_and_cloudwatch
    assert_equal 2, build("cloud_logging.jsonl")["summary"]["n"]
    r = build("cloudwatch.log")
    assert_equal 1, r["summary"]["n"]
    assert_equal 1, r["summary"]["platform_init_ms"]["n"]
    assert_equal 2, r["input"]["skipped_invalid"]
    assert_equal 1, r["input"]["skipped_other"]
  end

  def test_cloudwatch_events_json_document
    r = Hayaoki::ColdStartReport.build([fx("cloudwatch_events.json")])
    assert_equal 1, r["summary"]["n"]
    assert_equal 1, r["summary"]["platform_init_ms"]["n"]
  end

  def test_array_input
    arr = "[" + fx("cloud_logging.jsonl").lines.join(",") + "]"
    assert_equal 2, Hayaoki::ColdStartReport.build([arr])["summary"]["n"]
  end

  def test_key_order_independent
    line = JSON.generate(JSON.parse(fx("bare.jsonl").lines[0]).sort.to_h)
    assert_equal 1, Hayaoki::ColdStartReport.build(["2026 INFO #{line}\n"])["summary"]["n"]
  end

  def test_group_by_and_filters
    r = build("bare.jsonl", group_by: "revision")
    assert_equal %w[(none) redmine-00001 redmine-00002], r["groups"].keys
    assert_equal 2, r["groups"]["redmine-00001"]["n"]
    assert_equal %w[cloud_run lambda], build("bare.jsonl", group_by: "platform.kind")["groups"].keys
    assert_equal %w[on-demand], build("bare.jsonl", group_by: "init_type")["groups"].keys - ["(none)"]
    assert_equal 3, build("bare.jsonl", exclude_proactive: true)["summary"]["n"]
    assert_equal 1, build("bare.jsonl", since: Time.utc(2026, 11, 9))["summary"]["n"]
    assert_equal 3, build("bare.jsonl", until_: Time.utc(2026, 11, 9))["summary"]["n"]
  end

  def test_percentiles
    s = Hayaoki::ColdStartReport::Stats
    v = (1..100).to_a
    assert_equal [50, 90, 99, 100], [s.percentile(v, 50), s.percentile(v, 90), s.percentile(v, 99), s.percentile(v, 100)]
  end

  def test_cli_text_stdin
    code, out, = run_cli(["cold-start-report"], stdin: fx("bare.jsonl"))
    assert_equal 0, code
    assert_includes out, "4 cold start line(s)"
    assert_includes out, "to_first_response"
    assert_includes out, "issues#index"
  end

  def test_cli_json_files_group
    code, out, = run_cli(["cold-start-report", "--format", "json", "--group-by", "revision", File.join(FX, "bare.jsonl")])
    assert_equal 0, code
    j = JSON.parse(out)
    assert_equal "cold_start", j["hayaoki_report"]
    assert_equal 1, j["groups"]["redmine-00002"]["n"]
  end

  def test_cli_errors_and_help
    code, _, err = run_cli(["cold-start-report", "--since", "yesterday"])
    assert_equal 1, code
    assert_match(/invalid time/, err)
    assert_equal 1, run_cli(["cold-start-report", "/nonexistent/x"])[0]
    code, out, = run_cli(["cold-start-report", "--help"])
    assert_equal 0, code
    assert_includes out, "--group-by"
  end

  def test_empty_input
    code, out, = run_cli(["cold-start-report"], stdin: "garbage\n")
    assert_equal 0, code
    assert_includes out, "0 cold start line(s)"
  end

  def test_cloudwatch_insights_csv_dedup_and_status_split
    r = build("cloudwatch_insights.csv")
    assert_equal 3, r["input"]["lines"]
    assert_equal 1, r["input"]["skipped_duplicate"]
    assert_equal 0, r["input"]["skipped_invalid"]
    s = r["summary"]
    assert_equal({ "boot_error" => 1, "ok" => 2 }, s["status"])
    assert_equal 2, s["n_ok"]
    assert_equal 2, s["ready_ms"]["n"]
    out = Hayaoki::ColdStartReport::Formatters::Text.new.format(r)
    assert_includes out, "boot_error=1"
    assert_includes out, "1 duplicate"
  end

  def test_since_counts_rows_without_start_at
    r = build("cloudwatch_insights.csv", since: Time.iso8601("2026-01-01T00:00:00Z"))
    assert_equal 1, r["input"]["filtered_no_start_at"]
    assert_equal 2, r["input"]["lines"]
    assert_includes Hayaoki::ColdStartReport::Formatters::Text.new.format(r), "1 without start_at"
    _, out, = run_cli(%w[cold-start-report --help])
    assert_includes out, "without start_at"
  end

  # 0.2.0 lines can carry a bad /proc start (pre_load ~2 h on Cloud Run gen1): drop only the
  # start-based phases of that line and say so.
  def test_implausible_start_excluded_from_start_based_phases
    good = JSON.parse(fx("bare.jsonl").lines[0])
    bad = JSON.parse(JSON.generate(good)).merge("id" => "badstart")
    bad["phases_ms"].merge!("pre_load" => 7_209_434, "to_ready" => 7_211_232, "to_first_response" => 7_211_315)
    r = Hayaoki::ColdStartReport.build([[good, bad].map { JSON.generate(_1) }.join("\n")])
    s = r["summary"]
    assert_equal 1, s["implausible_start"]
    assert_equal 1, s["ready_ms"]["n"]
    assert_equal 1, s["first_response_ms"]["n"]
    %w[pre_load to_ready to_first_response].each { assert_equal 1, s["phases_ms"][_1]["n"], _1 }
    assert_equal good["phases_ms"]["to_ready"], s["ready_ms"]["max"]
    %w[initialize first_request].each { assert_equal 2, s["phases_ms"][_1]["n"], _1 }
    out = Hayaoki::ColdStartReport::Formatters::Text.new.format(r)
    assert_match(/warning: 1 line\(s\) with pre_load outside/, out)
    assert_equal 0, build("bare.jsonl")["summary"]["implausible_start"]
    refute_includes Hayaoki::ColdStartReport::Formatters::Text.new.format(build("bare.jsonl")), "warning:"
    assert_equal Hayaoki::Insitu::Emitter::MAX_PRE_LOAD_MS, Hayaoki::ColdStartReport::Stats::MAX_PRE_LOAD_MS
  end

  def test_from_load_includes_implausible_start_lines
    good = JSON.parse(fx("bare.jsonl").lines[0])
    bad = JSON.parse(JSON.generate(good)).merge("id" => "badstart")
    bad["phases_ms"].merge!("pre_load" => 3_500_000, "to_ready" => 3_502_000, "to_first_response" => 3_502_100)
    r = Hayaoki::ColdStartReport.build([[good, bad].map { JSON.generate(_1) }.join("\n")])
    s = r["summary"]
    assert_equal 1, s["ready_ms"]["n"]
    assert_equal 2, s["ready_from_load_ms"]["n"]
    assert_equal 2, s["first_response_from_load_ms"]["n"]
    assert_equal [2000, good["phases_ms"]["to_ready"] - good["phases_ms"]["pre_load"]].max, s["ready_from_load_ms"]["max"]
    assert_equal [2100, good["phases_ms"]["to_first_response"] - good["phases_ms"]["pre_load"]].max, s["first_response_from_load_ms"]["max"]
    assert_includes Hayaoki::ColdStartReport::Formatters::Text.new.format(r), "(from load)"
  end
end
