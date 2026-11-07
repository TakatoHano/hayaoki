# frozen_string_literal: true

require_relative "rule_helper"

class BootsnapIneffectiveTest < Minitest::Test
  include RuleHelper
  K = B::Rules::BootsnapIneffective
  Res = Struct.new(:payloads, :meta)

  def payload(ms) = { "status" => "ok", "boot_end_us" => ms * 1000 }

  def test_missing_bootsnap
    with_app("Gemfile" => %(gem "rails"\n)) do
      s = run_rule(K, make_report(gems: [gem_row("rails", 10)])).fetch(0)
      assert_equal :high, s.confidence
      assert_includes s.action, 'gem "bootsnap", require: false'
      assert_nil s.estimated_savings_ms
    end
  end

  def test_in_gemfile_but_not_loaded
    with_app("Gemfile" => %(gem "bootsnap", require: false\n)) do
      s = run_rule(K, make_report).fetch(0)
      assert_includes s.title, "does not seem to be loaded"
    end
  end

  def test_small_cold_warm_diff
    with_app do
      res = Res.new({ warm: [payload(980)] * 3, cold: [payload(1000)] * 3 }, {})
      s = run_rule(K, make_report(gems: [gem_row("bootsnap", 5)]), result: res)
      assert_equal 1, s.size
      assert_includes s[0].title, "little benefit"
      assert_equal 20.0, s[0].evidence[0]["diff_ms"]
    end
  end

  def test_large_diff_is_fine
    with_app do
      res = Res.new({ warm: [payload(600)], cold: [payload(1000)] }, {})
      assert_empty run_rule(K, make_report(gems: [gem_row("bootsnap", 5)]), result: res)
    end
  end

  def test_symbol_keyed_result
    with_app do
      res = Res.new({ warm: [{ status: "ok", boot_end_us: 990_000 }], cold: [{ status: "ok", boot_end_us: 1_000_000 }] }, {})
      assert_equal 1, run_rule(K, make_report(gems: [gem_row("bootsnap", 5)]), result: res).size
    end
  end

  def test_cache_warning
    with_app do
      w = "[warm] BOOTSNAP_CACHE_DIR was not used (the app may ...)"
      s = run_rule(K, make_report(gems: [gem_row("bootsnap", 5)], warnings: [w]))
      assert_equal 1, s.size
      assert_includes s[0].title, "cache directory stayed empty"
    end
  end

  def test_healthy
    with_app { assert_empty run_rule(K, make_report(gems: [gem_row("bootsnap", 5)])) }
  end
end
