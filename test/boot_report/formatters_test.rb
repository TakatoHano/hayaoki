# frozen_string_literal: true

require "test_helper"
require "hayate"
require "hayate/boot_report/report"
require "hayate/boot_report/formatters/text"
require "hayate/boot_report/formatters/json"
require "hayate/boot_report/formatters/speedscope"

class BootReportFormattersTest < Minitest::Test
  def st(m, lo = nil, hi = nil) = { "median" => m, "min" => lo || m - 1, "max" => hi || m + 1 }

  def report(cond, scale = 1.0)
    Hayate::BootReport::Report.new(
      condition: cond, runs: 3, failed: 0,
      phases: { "vm_boot" => st(40 * scale), "bundler_require" => st(300 * scale), "initialize" => st(500 * scale),
                "eager_load" => nil, "boot" => st(900 * scale), "total" => st(940 * scale, 900, 990) },
      categories: {}, files: [],
      gems: [{ "name" => "activesupport", "category" => "gem", "self_ms" => st(120.5 * scale), "require_ms" => st(100 * scale),
               "on_load_ms" => st(10 * scale), "initializer_count" => st(2) },
             { "name" => "app", "category" => "app", "self_ms" => st(30 * scale), "require_ms" => st(30 * scale),
               "on_load_ms" => st(0), "initializer_count" => st(0) }],
      initializers: [{ "name" => "active_record.initialize_database", "context" => nil, "inclusive_ms" => st(55 * scale), "self_ms" => st(50) }],
      on_loads: [{ "name" => "active_record", "source" => "a.rb:1", "inclusive_ms" => st(44 * scale), "self_ms" => st(40) }],
      false_require: { "count" => st(7, 7, 7), "time_ms" => st(2.5) },
      threads: {}, ruby: "x", features: nil,
      meta: { "runs" => 3, "env" => "production", "bootsnap" => "warm", "overhead" => { cond => { "baseline_ms" => 800.0, "probe_ms" => 810.0, "diff_ms" => 10.0, "ratio" => 1.0125 } } },
      warnings: ["something odd"]
    )
  end

  def test_text_single
    out = Hayate::BootReport::Formatters::Text.new(top: 1).format("warm" => report("warm"))
    assert_includes out, "runs=3 env=production bootsnap=warm"
    assert_includes out, "940.0 ms [900.0-990.0]"
    assert_includes out, "█"
    assert_includes out, "activesupport"
    refute_includes out, "\n  app "  # top: 1
    assert_includes out, "active_record.initialize_database"
    assert_includes out, "count: 7"
    assert_includes out, "something odd"
    assert_includes out, "baseline 800.0"
    assert out.lines.all? { _1.chomp.length <= 80 }, "width"
    refute_match(/\e\[/, out)
  end

  def test_text_both_shows_diff
    out = Hayate::BootReport::Formatters::Text.new.format("warm" => report("warm"), "cold" => report("cold", 2.0))
    assert_includes out, "total[warm]"
    assert_includes out, "total[cold]"
    assert_includes out, "diff (cold - warm): +940.0 ms (+100.0%)"
    assert_includes out, "+120.5"
    assert out.lines.all? { _1.chomp.length <= 80 }
  end

  def test_json_round_trip
    r = report("warm")
    doc = JSON.parse(Hayate::BootReport::Formatters::Json.new.format("warm" => r))
    assert_equal 1, doc["schema_version"]
    assert_equal Hayate::VERSION, doc["hayate_version"]
    assert_equal JSON.parse(JSON.generate(r.to_h)), doc["reports"]["warm"]
  end

  # width 8: [kind, name, parent, t0, t1, res, tid, cpu]
  def payload(total)
    ev = []
    ev.push(7, "initialize", -1, 0, total, nil, 0, nil)         # idx 0
    ev.push(0, "a", 0, 10, 60, "a.rb", 0, nil)                  # idx 8
    ev.push(0, "b", 8, 20, 50, "b.rb", 0, nil)                  # idx 16
    ev.push(3, "init", 0, 70, nil, nil, 0, nil)                 # idx 24 open span
    ev.push(0, "bg", -1, 5, 500, "bg.rb", 12345, nil)           # background thread
    { "status" => "ok", "width" => 8, "events" => ev, "exit_us" => total, "boot_end_us" => total }
  end

  def test_speedscope_structure
    f = Hayate::BootReport::Formatters::Speedscope.new
    doc = JSON.parse(f.format([payload(300), payload(100), payload(200)]))
    assert_equal "https://www.speedscope.app/file-format-schema.json", doc["$schema"]
    frames = doc["shared"]["frames"]
    prof = doc["profiles"].first
    assert_equal "evented", prof["type"]
    %w[name unit startValue endValue events].each { assert prof.key?(_1), _1 }
    names = frames.map { _1["name"] }
    refute_includes names.join, "bg"
    assert_equal 200, prof["endValue"]  # median run
    stack = []
    last = 0
    prof["events"].each do |e|
      assert_operator e["at"], :>=, last
      last = e["at"]
      assert_operator e["frame"], :<, frames.size
      if e["type"] == "O" then stack.push(e["frame"])
      else assert_equal stack.pop, e["frame"]
      end
    end
    assert_empty stack
    assert_operator last, :<=, prof["endValue"]
    assert_equal 4, prof["events"].count { _1["type"] == "O" }
  end
end

class BootReportFormattersExtraTest < Minitest::Test
  def test_redact
    require "hayate/boot_report/formatters/redact"
    r = Hayate::BootReport::Formatters::Redact.new(app_dir: "/Users/x/app", home: "/Users/x")
    out = r.apply('["/Users/x/app/a.rb","/Users/x/.gem/ruby/3.4.0/gems/rack-3.0.1/lib/rack.rb","/Users/x/y"]')
    assert_equal '["<app>/a.rb","<gem:rack>/lib/rack.rb","~/y"]', out
  end

  def test_cli_accepts_redact
    require "hayate/cli"
    opts, = Hayate::CLI.new.parse(%w[--redact])
    assert opts[:redact]
  end
end
