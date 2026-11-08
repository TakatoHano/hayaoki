# frozen_string_literal: true

require "test_helper"
require "pathname"

# recorder / encoder / require_relative / 診断の単体テスト
class ProbeRecorderTest < Minitest::Test
  include ProbeHelper

  def test_false_require_is_not_a_span_but_counted
    rep = run_probe('require "./t_leaf"; require "./t_leaf"; require "./t_leaf"').report
    assert_equal 1, rep.feature("t_leaf.rb").size
    assert_equal 1, rep.spans.size
    assert_equal 2, rep["false_require"]["count"]
    assert_operator rep["false_require"]["time_us"], :>=, 0
  end

  def test_pathname_argument_is_kept_and_written_as_string
    rep = run_probe('require "pathname"; require Pathname.new(File.expand_path("t_leaf"))').report
    leaf = rep.feature("t_leaf.rb").first
    assert_kind_of String, leaf.name
    assert_equal File.join(File.realpath(File.join(FIXTURES, "edge")), "t_leaf"), File.realpath(File.dirname(leaf.name)) + "/" + File.basename(leaf.name)
  end

  def test_load_is_recorded_as_kind_load
    rep = run_probe('load "./t_leaf.rb"; load "./t_leaf.rb"').report
    loads = rep.of_kind(ProbeReport::K_LOAD)
    assert_equal 2, loads.size, "load runs every time and is not a false-require"
    assert_equal "./t_leaf.rb", loads.first.name
  end

  def test_boot_end_is_the_close_of_the_last_depth0_main_span
    rep = run_probe('require "./t_main"; at_exit { sleep 0.05 }').report
    main = rep.feature("t_main.rb").first
    assert_equal main.t1, rep["boot_end_us"]
    assert_operator rep["exit_us"] - rep["boot_end_us"], :>=, 40_000, "at_exit time is not part of boot"
  end

  def test_payload_schema
    rep = run_probe('require "./t_leaf"', env: { "HAYATE_SPAWN_AT" => "1.5" }).report
    %w[v status error pid ruby platform t0_real spawn_at cpu0_us boot_end_us exit_us pre_features features gc
       false_require width events specs rails_root pwd_realpath libdir probe_errors probe_warnings pending_hooks].each do |k|
      assert rep.data.key?(k), "missing key #{k}"
    end
    assert_equal 1, rep["v"]
    assert_equal 8, rep["width"]
    assert_equal RUBY_VERSION, rep["ruby"]
    assert_equal 0, rep["events"].size % 8
    assert_equal %w[count0 count1 time0_ms time1_ms], rep["gc"].keys
    assert_equal "1.5", rep["spawn_at"]
    assert_nil rep["rails_root"]
    assert_equal File.realpath(File.join(FIXTURES, "edge")), rep["pwd_realpath"]
    assert_equal %w[/bundler/runtime.rb /rails/application.rb /rails/initializable.rb /active_support/lazy_load_hooks.rb /zeitwerk/loader.rb
                    /active_support/deprecation/reporting.rb].sort,
                 rep["pending_hooks"].sort
    assert_equal ["error_highlight", "did_you_mean"].sort - rep["specs"].keys, []
    name, (ver, path, _ext) = rep["specs"].first
    assert_kind_of String, name
    assert_kind_of String, ver
    assert_kind_of String, path
  end

  def test_no_output_when_out_is_not_given
    Dir.mktmpdir do |d|
      so, se, st = Open3.capture3(CLEAN_ENV, RbConfig.ruby, "-r#{PROBE}", "-e", "1", chdir: d)
      assert_predicate st, :success?
      assert_empty so + se
    end
  end

  def test_require_relative_without_basepath_raises_like_native
    r = run_probe('begin; eval(%q(require_relative "t_leaf")); rescue LoadError => e; puts e.message; end')
    assert_equal "cannot infer basepath", r.out.strip
  end

  def test_require_relative_in_dash_e_is_relative_to_cwd_like_native
    native, = Open3.capture2e(CLEAN_ENV, RbConfig.ruby, "-e", 'require_relative "t_leaf"; puts :ok', chdir: File.join(FIXTURES, "edge"))
    r = run_probe('require_relative "t_leaf"; puts :ok')
    assert_equal native, r.out
    assert_equal 1, r.report.feature("t_leaf.rb").size
  end

  def test_require_relative_through_symlinked_directory_matches_native
    Dir.mktmpdir("hayate-symlink") do |d|
      d = File.realpath(d)
      FileUtils.mkdir_p("#{d}/real/sub")
      File.write("#{d}/real/target.rb", 'puts "real target"')
      File.write("#{d}/target.rb", 'puts "WRONG target (symlink-parent)"')
      File.write("#{d}/real/sub/a.rb", 'require_relative "../target"')
      File.symlink("#{d}/real/sub", "#{d}/link")
      native, = Open3.capture2e(CLEAN_ENV, RbConfig.ruby, "-e", 'require "./link/a"', chdir: d)
      r = run_probe('require "./link/a"', chdir: d)
      assert_equal native, r.out
      assert_equal "real target\n", r.out
    end
  end

  def test_require_overridden_without_alias_is_reported_as_warning
    code = 'Kernel.module_eval { define_method(:require) { |p| gem_original_require(p) } }; require "./t_leaf"'
    r = run_probe(code)
    rep = r.report
    assert_equal "ok", rep["status"]
    assert_equal 0, rep.spans.size
    assert(rep["probe_warnings"].any? { |w| w.include?("no require was recorded") }, rep["probe_warnings"].inspect)
  end

  def test_late_install_failure_does_not_break_boot_and_is_recorded
    code = <<~'RUBY'
      module Zeitwerk; end
      Hayate::Probe.send(:remove_const, :EagerLoadHook)
      require "zeitwerk/loader"
    RUBY
    r = run_probe(code, chdir: FIXTURES, ruby_args: ["-I#{FIXTURES}/fake_rails/lib"])
    assert_equal "ok", r.report["status"], r.err
    assert(r.report["probe_errors"].any? { |e| e.include?("install_eager_load") }, r.report["probe_errors"].inspect)
  end

  def test_hooks_installed_immediately_when_target_is_already_defined
    # すでに Zeitwerk::Loader が定義済みの状態で probe を読み込む
    code = %(require "zeitwerk/loader"; load #{PROBE.dump}; Zeitwerk::Loader.new("late").eager_load)
    r = run_probe(code, chdir: FIXTURES, probe_args: [], ruby_args: ["-I#{FIXTURES}/fake_rails/lib"])
    assert_equal "ok", r.report["status"], r.err
    assert_equal 1, r.report.named(ProbeReport::K_EAGER, "late").size
    refute_includes r.report["pending_hooks"], "/zeitwerk/loader.rb"
  end

  def test_json_encoder_round_trips_awkward_values
    code = <<~'RUBY'
      require "pathname"
      v = {
        "ctl" => "a\u0001b\u001f\n\t\r\"\\ /",
        :sym => :value, "bin" => "\xff\xfe abc".b, "bad" => "ok\xE3\x81".dup.force_encoding("UTF-8"),
        "path" => Pathname.new("/tmp/x y"), "uni" => "日本語 \u{1F600}", "arr" => [1, -2, 3.5, nil, true, false, []],
        "nested" => { "a" => { "b" => [{}] } }, "int" => 12345678901234567890, "inf" => Float::INFINITY, "obj" => Object,
      }
      print Hayate::Probe.encode(v)
    RUBY
    r = run_probe(code)
    h = JSON.parse(r.out)
    assert_equal "a\u0001b\u001f\n\t\r\"\\ /", h["ctl"]
    assert_equal "value", h["sym"]
    assert_equal "�� abc", h["bin"]
    assert_equal "ok�", h["bad"]
    assert_equal "/tmp/x y", h["path"]
    assert_equal "日本語 \u{1F600}", h["uni"]
    assert_equal [1, -2, 3.5, nil, true, false, []], h["arr"]
    assert_equal({ "a" => { "b" => [{}] } }, h["nested"])
    assert_equal 12345678901234567890, h["int"]
    assert_nil h["inf"]
    assert_equal "Object", h["obj"]
  end

  def test_json_is_not_required_by_probe
    r = run_probe('print $LOADED_FEATURES.grep(%r{/json[./]}).size; require "./t_leaf"')
    assert_equal "0", r.out
    refute(r.report.spans.any? { |s| s.name.to_s.include?("json") })
  end

  def test_json_encoding_survives_non_utf8_require_name
    rep = run_probe('require "./t_leaf"; begin; require "./no_such_\xff".b; rescue LoadError; end').report
    assert_equal "ok", rep["status"]
    assert_equal 2, rep.spans.size
  end
end
