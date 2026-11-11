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

  # --- INIT_REPORT (Lambda platform lines)

  INIT_TIMEOUT = "INIT_REPORT Init Duration: 9999.61 ms\tPhase: init\tStatus: timeout"
  INIT_ERROR = "INIT_REPORT Init Duration: 1200.00 ms\tPhase: invoke\tStatus: error"

  def init_reports(text) = Hayaoki::ColdStartReport.build([text])["summary"]["platform_init_reports"]

  def test_init_report_plain_text
    text = "2026-11-08T03:12:40.000Z\t#{INIT_TIMEOUT}\n#{INIT_ERROR}\n1794000000000\t#{INIT_TIMEOUT}\n" + fx("cloudwatch.log")
    r = Hayaoki::ColdStartReport.build([text])
    assert_equal [{ "phase" => "init", "status" => "timeout", "count" => 2 }, { "phase" => "invoke", "status" => "error", "count" => 1 }],
                 r["summary"]["platform_init_reports"]
    assert_equal 4, r["summary"]["platform_init_ms"]["n"]
    assert_equal 2, r["input"]["skipped_invalid"]
    assert_includes Hayaoki::ColdStartReport::Formatters::Text.new.format(r), "INIT_REPORT lines: init/timeout x2, invoke/error x1"
    assert_nil init_reports(fx("cloudwatch.log"))
  end

  def test_init_report_cloudwatch_export_and_json_array
    events = { "events" => [{ "timestamp" => 1, "message" => "#{INIT_TIMEOUT}\n" }, { "timestamp" => 2, "message" => "#{INIT_ERROR}\n" }] }
    want = [{ "phase" => "init", "status" => "timeout", "count" => 1 }, { "phase" => "invoke", "status" => "error", "count" => 1 }]
    assert_equal want, init_reports(JSON.generate(events))
    assert_equal want, init_reports(JSON.generate(events["events"]))
    # JSONL of events: each platform line counted once
    r = Hayaoki::ColdStartReport.build([events["events"].map { JSON.generate(_1) }.join("\n")])
    assert_equal want, r["summary"]["platform_init_reports"]
    assert_equal 2, r["summary"]["platform_init_ms"]["n"]
    csv = %Q("@timestamp","@message"\n"2026-11-08 03:12:40.000","#{INIT_TIMEOUT}"\n)
    assert_equal [want[0]], init_reports(csv)
  end

  # --- hints output

  def hint_line(i, ready: 6800, bootsnap: false, pre_load: 400)
    { "hayaoki" => "cold_start", "v" => 1, "status" => "ok", "id" => "h#{i}", "pid" => 1,
      "platform" => { "kind" => "lambda", "function" => "fn", "memory_mb" => 1024, "init_type" => "on-demand" },
      "runtime" => { "bootsnap" => bootsnap, "bootsnap_cache" => nil },
      "phases_ms" => { "pre_load" => pre_load, "to_ready" => ready, "to_first_response" => ready + 200 },
      "proc" => { "cpu_ms" => 5000, "gc_time_ms" => 1500, "gc_count" => 30 } }
  end

  def hint_input(n, **kw) = Array.new(n) { |i| JSON.generate(hint_line(i, **kw)) }.join("\n") + "\n"

  def test_hints_text_three_none_and_too_few
    r = Hayaoki::ColdStartReport.build([hint_input(5, ready: 8000) + INIT_TIMEOUT + "\n"])
    out = Hayaoki::ColdStartReport::Formatters::Text.new.format(r)
    assert_includes out, "Hints (likely causes outside app code; based on 5 ok cold starts, 5 with a plausible start)"
    refute_includes out, "Start-based hints"
    rows = out.lines.grep(/^  (likely|possible|note) /).map { _1.split[0..1] }
    assert_equal [%w[likely bootsnap_off], %w[likely lambda_init_near_limit], %w[possible gc_pressure]], rows
    assert_includes out, "Cannot see: AWS_LWA_ASYNC_INIT, image pull and layer caching, RUBY_GC_* settings"
    assert_includes out, "These hints do not cover how often users hit a cold start (min instances)."

    out = Hayaoki::ColdStartReport::Formatters::Text.new.format(Hayaoki::ColdStartReport.build([hint_input(6, ready: 1800, bootsnap: true)]))
    assert_includes out, "Hints: none (n=6)"
    refute_includes out, "min instances"

    out = Hayaoki::ColdStartReport::Formatters::Text.new.format(Hayaoki::ColdStartReport.build([hint_input(2)]))
    assert_includes out, "Hints: hints need at least 3 ok cold starts with a plausible start (have 2)"
  end

  def test_hints_json
    j = JSON.parse(Hayaoki::ColdStartReport::Formatters::Json.new.format(Hayaoki::ColdStartReport.build([hint_input(5, ready: 8000)])))
    h = j["summary"]["hints"]
    assert_equal %w[bootsnap_off lambda_init_near_limit gc_pressure], h.map { _1["id"] }
    assert_equal %w[cannot_see evidence id level message mixed n], h[0].keys.sort
    assert_equal [5, false], [h[0]["n"], h[0]["mixed"]]
    assert_equal 5, j["summary"]["hints_n"]
    j = JSON.parse(Hayaoki::ColdStartReport::Formatters::Json.new.format(Hayaoki::ColdStartReport.build([hint_input(6, ready: 1800, bootsnap: true)])))
    assert_equal [], j["summary"]["hints"]
    j = JSON.parse(Hayaoki::ColdStartReport::Formatters::Json.new.format(Hayaoki::ColdStartReport.build([hint_input(2)])))
    assert_equal [[], 2], [j["summary"]["hints"], j["summary"]["hints_n"]]
  end

  # gen2-shaped lines that waited off CPU with no run-queue wait: wait_kind not_cpu with counters
  def wait_input(n)
    Array.new(n) do |i|
      JSON.generate({ "hayaoki" => "cold_start", "v" => 1, "status" => "ok", "id" => "w#{i}", "pid" => 1,
                      "platform" => { "kind" => "cloud_run", "service" => "svc", "revision" => "svc-00001-abc" },
                      "runtime" => { "bootsnap" => true, "bootsnap_cache" => true },
                      "limits" => { "cgroup" => "v2", "cpu_quota" => 2.086, "nproc" => 2, "mem_max_mb" => 1024, "sandbox" => nil },
                      "phases_ms" => { "pre_load" => 400, "to_ready" => 6800, "to_first_response" => 7000 },
                      "proc" => { "cpu_ms" => 1700, "cpu_at_load_ms" => 100, "gc_time_ms" => 100, "gc_count" => 10, "rss_kb" => 100_000,
                                  "main_thread_runq_wait_ms" => 3, "main_thread_runq_wait_at_load_ms" => 2,
                                  "majflt" => 900, "majflt_at_load" => 50, "psi_io_some_ms" => 4000, "psi_io_some_at_load_ms" => 100,
                                  "steal_ms" => 10, "steal_at_load_ms" => 0 } })
    end.join("\n") + "\n"
  end

  def test_wait_split_in_text_and_json
    r = Hayaoki::ColdStartReport.build([wait_input(4)])
    out = Hayaoki::ColdStartReport::Formatters::Text.new.format(r)
    assert_includes out, "wait_dominated_boot"
    assert_includes out, "It was not waiting for a CPU: the main thread waited in the run queue for 1 ms"
    assert_includes out, "850 major page faults, system-wide IO stall (PSI) 3.9 s, system-wide steal 10 ms summed over 2 CPUs."
    assert_includes out, "IO stall time (PSI) covers most of the wait, so file IO is the likely main cause"
    j = JSON.parse(Hayaoki::ColdStartReport::Formatters::Json.new.format(r))
    h = j["summary"]["hints"].find { _1["id"] == "wait_dominated_boot" }
    assert_equal ["not_cpu", 4, 850, 3900, 10], h["evidence"].values_at("wait_kind", "wait_lines", "majflt_p50", "psi_io_some_ms_p50", "steal_ms_p50")
    %w[non_cpu_ms_p50 runq_share_of_non_cpu_p50 io_read_bytes_p50 psi_cpu_some_ms_p50 unaccounted_ms_p50].each { assert h["evidence"].key?(_1), _1 }
    assert_match(/It was not waiting for a CPU/, h["message"])
  end

  def test_hints_per_group_and_no_hints_flag
    other = hint_input(3, bootsnap: true).gsub('"memory_mb":1024', '"memory_mb":2048').gsub('"id":"h', '"id":"g')
    code, out, = run_cli(%w[cold-start-report --group-by memory_mb], stdin: hint_input(3) + other)
    assert_equal 0, code
    assert_equal 2, out.scan(/^Hints/).size
    assert_match(/== memory_mb: 1024 ==.*bootsnap_off.*== memory_mb: 2048 ==/m, out)
    refute_includes out.split("== memory_mb: 2048 ==").last, "bootsnap_off"
    _, out, = run_cli(%w[cold-start-report], stdin: hint_input(3) + other)
    assert_includes out, "Lines come from different configurations (memory_mb, bootsnap); try --group-by memory_mb."
    _, out, = run_cli(%w[cold-start-report --no-hints], stdin: hint_input(3))
    refute_includes out, "Hints"
    _, out, = run_cli(%w[cold-start-report --no-hints --format json], stdin: hint_input(3))
    refute JSON.parse(out)["summary"].key?("hints")
    assert_includes run_cli(%w[cold-start-report --help])[1], "--no-hints"
  end

  # Fixtures hold placeholder values only: no long hex IDs, account numbers, ARNs or emails.
  def test_fixtures_have_no_real_ids
    bad = /\b[0-9a-f]{16,}\b|\b\d{12}\b|arn:aws:|[\w.+-]+@[\w-]+\.(?:com|net|org|io|jp|dev)\b/
    hits = Dir[File.join(FIXTURES, "**", "*")].select { File.file?(_1) }.flat_map do |f|
      File.read(f, mode: "rb").force_encoding("UTF-8").scrub.lines.each_with_index.filter_map { |l, i| "#{f}:#{i + 1}" if l.match?(bad) }
    end
    assert_empty hits
  end
end
