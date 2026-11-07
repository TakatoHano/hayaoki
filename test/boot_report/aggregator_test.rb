# frozen_string_literal: true

require "test_helper"
require "hayate/boot_report/aggregator"

class BootReportAggregatorTest < Minitest::Test
  A = Hayate::BootReport::Aggregator
  W = 8

  # 合成 payload を作る。events は [kind, name, parent_index(span 番号 or nil), t0, t1, res] の配列 (µs)。
  def payload(spans, **over)
    ev = []
    spans.each do |kind, name, parent, t0, t1, res, tid|
      ev.push(kind, name, parent ? parent * W : -1, t0, t1, res, tid || 0, nil)
    end
    {
      "v" => 1, "status" => "ok", "ruby" => "4.0.0", "t0_real" => 1000.030, "spawn_at" => "1000.0",
      "boot_end_us" => 1000, "exit_us" => 1100, "features" => 10, "width" => W, "events" => ev,
      "specs" => {
        "foo" => ["1.0", "/gems/foo-1.0", "/gems/ext/foo-1.0"],
        "foo-extra" => ["1.0", "/gems/foo-1.0-extra", nil],
        "bar" => ["2.0", "/app/vendor/bar", nil],
      },
      "rails_root" => "/app", "pwd_realpath" => "/app",
      "libdir" => ["/ruby/lib/ruby/4.0.0", "/ruby/lib/ruby/4.0.0/arm64-darwin"],
      "false_require" => { "count" => 3, "time_us" => 1500 },
      "probe_errors" => [], "probe_warnings" => [],
    }.merge(over)
  end

  # foo_extra: foo の require を伸ばす (run ごとの差を作る)
  def run_payload(foo_extra: 0)
    f = foo_extra
    payload([
      [0, "./config/environment", nil, 0, 1000 + f, "/app/config/environment.rb"],                          # 0
      [7, "bundler_require", 0, 100, 400 + f, nil],                                                         # 1
      [1, "/gems/foo-1.0/lib/foo.rb", 1, 120, 300 + f, "/gems/foo-1.0/lib/foo.rb"],                         # 2 require_relative
      [0, "foo", 2, 121, 299 + f, "/gems/foo-1.0/lib/foo.rb"],                                              # 3 二重記録 (統合される)
      [0, "foo/ext", 3, 130, 170, "/gems/ext/foo-1.0/foo.so"],                                              # 4 extension_dir
      [0, "foo-extra", 3, 180, 200, "/gems/foo-1.0-extra/lib/foo-extra.rb"],                                # 5 接頭辞の境界
      [7, "initialize", 0, 400, 900 + f, nil],                                                              # 6
      [3, "load_config_initializers", 6, 450, 700, ["Rails::Application", "/gems/foo-1.0/lib/foo/railtie.rb:10"]], # 7
      [2, "/app/config/initializers/spike.rb", 7, 460, 660, "/app/config/initializers/spike.rb"],           # 8
      [4, "action_controller", 6, 720, 800, "/gems/foo-1.0/lib/foo.rb:4"],                                  # 9
      [0, "set", 6, 810, 830, "/ruby/lib/ruby/4.0.0/set.rb"],                                               # 10 stdlib
      [0, "x", 6, 840, 850, "/other/x.rb"],                                                                 # 11 other
      [0, "bar", 6, 855, 865, "/app/vendor/bar/lib/bar.rb"],                                                # 12 rails_root 配下でも gem が勝つ
      [5, "action_controller", 6, 720, 800, "ActionController::Base"],                                      # 13 hooks (帰属しない)
      [0, "t", nil, 10, 90, "/gems/foo-1.0/lib/t.rb", 12345],                                               # 14 バックグラウンドスレッド
    ])
  end

  def agg(payloads, **kw) = A.new.aggregate(payloads, **kw)

  def gem_row(report, name) = report.gems.find { _1["name"] == name }

  def test_attribution_and_self_time
    r = agg([run_payload])
    # foo: foo.rb (統合後の 1 span) 自身 = 180 - (40 ext + 20 foo-extra) は ext が foo なので
    # foo.rb self=180-40-20=120, ext=40, railtie の initializer self=250-200=50, on_load=80 => 290 us
    foo = gem_row(r, "foo")
    # initializer 本体の自己時間 (0.050) は gem に付けない (init_body_ms として別掲)
    assert_in_delta 0.120 + 0.040 + 0.080, foo["self_ms"]["median"], 1e-6
    refute foo.key?("initializer_ms")
    assert_operator foo["initializer_count"]["median"], :>=, 1
    assert_in_delta 0.160, foo["require_ms"]["median"], 1e-6
    assert_in_delta 0.080, foo["on_load_ms"]["median"], 1e-6
    assert_in_delta 0.020, gem_row(r, "foo-extra")["self_ms"]["median"], 1e-6, "foo-1.0 は foo-1.0-extra に前方一致しない"
    assert_in_delta 0.010, gem_row(r, "bar")["self_ms"]["median"], 1e-6, "最長一致: rails_root 配下の path gem は gem"
    assert_equal "app", gem_row(r, "app")["name"]
    assert_equal "app", gem_row(r, "app")["category"]
    assert_equal "stdlib", gem_row(r, "stdlib")["category"]
    assert_in_delta 0.020, gem_row(r, "stdlib")["self_ms"]["median"], 1e-6
    assert_equal "other", gem_row(r, "other")["category"]
    assert_equal "gem", foo["category"]
    # app: environment.rb (1000 - bundler_require 300 - initialize 500 = 200) + spike.rb 200 = 400us
    assert_in_delta 0.400, gem_row(r, "app")["self_ms"]["median"], 1e-6
    assert_equal %w[app foo], r.gems.first(2).map { _1["name"] }, "self time の降順"
  end

  def test_unattributed_category_is_boot_minus_attributed
    r = agg([run_payload])
    attributed = r.categories.reject { |k, _| k == "unattributed" }.sum { |_, v| v["self_ms"]["median"] }
    assert_in_delta 1.0 - attributed, r.categories["unattributed"]["self_ms"]["median"], 1e-6
    assert_operator r.categories["unattributed"]["self_ms"]["median"], :>, 0
    assert_in_delta 0.050, r.categories["init_body"]["self_ms"]["median"], 1e-6
  end

  def test_app_that_is_itself_a_gem_is_categorized_as_app
    p = payload([
      [0, "./config/environment", nil, 0, 1000, "/app/config/environment.rb"],
      [0, "mylib", 0, 100, 300, "/app/lib/mylib.rb"],
      [0, "dep", 0, 400, 500, "/app/vendor/dep/lib/dep.rb"],
    ], "specs" => { "myapp" => ["0.1", "/app", nil], "dep" => ["1.0", "/app/vendor/dep", nil] })
    r = agg([p])
    assert_equal "app", gem_row(r, "app")["category"]
    assert_in_delta 0.9, gem_row(r, "app")["self_ms"]["median"], 1e-6
    assert_nil gem_row(r, "myapp")
    assert_equal "gem", gem_row(r, "dep")["category"]
  end

  def test_files_use_self_time_and_merge_double_recording
    r = agg([run_payload])
    foo_rb = r.files.select { _1["path"] == "/gems/foo-1.0/lib/foo.rb" }
    assert_equal 1, foo_rb.size, "require_relative と require の二重記録は 1 件に統合される"
    assert_in_delta 0.120, foo_rb[0]["self_ms"]["median"], 1e-6
    assert_in_delta 0.180, foo_rb[0]["inclusive_ms"]["median"], 1e-6
    assert_equal "foo", foo_rb[0]["owner"]
    assert_equal 1, r.threads["merged_duplicates"]
    selfs = r.files.map { _1["self_ms"]["median"] }
    assert_equal selfs.sort.reverse, selfs, "self time の降順"
  end

  def test_initializers_on_loads_and_phases
    r = agg([run_payload])
    i = r.initializers.find { _1["name"] == "load_config_initializers" }
    assert_in_delta 0.250, i["inclusive_ms"]["median"], 1e-6
    assert_in_delta 0.050, i["init_body_ms"]["median"], 1e-6
    refute i.key?("self_ms")
    full = r.app_initializer_times
    assert_equal ["/app/config/initializers/spike.rb"], full["files"].map { _1["path"] }
    assert_in_delta 0.200, full["files"][0]["inclusive_ms"]["median"], 1e-6
    assert_equal "foo", i["owner"]
    o = r.on_loads.find { _1["name"] == "action_controller" }
    assert_in_delta 0.080, o["inclusive_ms"]["median"], 1e-6
    assert_equal "foo", o["owner"]
    assert_equal "/gems/foo-1.0/lib/foo.rb:4", o["source"]
    ph = r.phases
    assert_in_delta 30.0, ph["vm_boot"]["median"], 1e-3
    assert_in_delta 0.300, ph["bundler_require"]["median"], 1e-6
    assert_in_delta 0.500, ph["initialize"]["median"], 1e-6
    assert_nil ph["eager_load"]
    assert_in_delta 31.0, ph["total"]["median"], 1e-3
    assert_equal({ "count" => { "median" => 3, "min" => 3, "max" => 3 }, "time_ms" => { "median" => 1.5, "min" => 1.5, "max" => 1.5 } }, r.false_require)
  end

  def test_background_threads_are_excluded
    r = agg([run_payload])
    assert_equal 1, r.threads["background_spans"]
    assert(r.warnings.any? { _1.include?("background") })
    refute(r.files.any? { _1["path"].end_with?("/t.rb") })
  end

  def test_median_min_max_across_runs
    # foo.rb の self time は 120 + extra: 0 / 100 / 1000 / 200 us (偶数個 -> 中央 2 つの平均)
    r = agg([0, 100, 1000, 200].map { run_payload(foo_extra: _1) })
    assert_equal 4, r.runs
    row = r.files.find { _1["path"] == "/gems/foo-1.0/lib/foo.rb" }["self_ms"]
    assert_in_delta 0.270, row["median"], 1e-6 # (220 + 320) / 2
    assert_in_delta 0.120, row["min"], 1e-6
    assert_in_delta 1.120, row["max"], 1e-6
    r3 = agg([0, 100, 1000].map { run_payload(foo_extra: _1) })
    assert_in_delta 0.220, r3.files.find { _1["path"] == "/gems/foo-1.0/lib/foo.rb" }["self_ms"]["median"], 1e-6
    total = r3.phases["initialize"]
    assert_in_delta 0.600, total["median"], 1e-6
    assert_in_delta 1.500, total["max"], 1e-6
  end

  def test_missing_value_in_a_run_counts_as_zero
    a = run_payload
    c = run_payload
    c["events"] = c["events"].each_slice(W).reject { |e| e[1] == "bar" }.flatten(1) # span 12 を除く (後続の親添字は 6 までなのでずれない)
    row = gem_row(agg([a, c, c]), "bar")["self_ms"]
    assert_equal [0, 0, 0.01], [row["median"], row["min"], row["max"]]
  end

  def test_incomplete_spans_are_closed_at_exit_and_failed_runs_excluded
    p1 = run_payload
    p1["events"][4] = nil # environment.rb が未完了
    r = agg([p1, run_payload, run_payload.merge("status" => "error")])
    assert_equal 2, r.runs
    assert_equal 1, r.failed
    assert_equal "app", gem_row(r, "app")["name"]
  end

  def test_to_h_is_json_serializable
    h = agg([run_payload, run_payload(foo_extra: 50)], condition: "warm", meta: { "warnings" => ["w"] }).to_h
    back = JSON.parse(JSON.generate(h))
    assert_equal "warm", back["condition"]
    assert_equal 2, back["runs"]
    assert_includes back["warnings"], "w"
    %w[phases gems files initializers on_loads false_require].each { assert back.key?(_1), _1 }
  end

  def test_eager_load_nested_is_not_double_counted
    p = run_payload
    base = p["events"].each_slice(W).to_a
    base << [6, "main", 6 * W, 500, 600, nil, 0, nil] # span 15
    base << [6, "inner", 15 * W, 510, 590, nil, 0, nil]
    p["events"] = base.flatten(1)
    assert_in_delta 0.100, agg([p]).phases["eager_load"]["median"], 1e-6
  end
end
