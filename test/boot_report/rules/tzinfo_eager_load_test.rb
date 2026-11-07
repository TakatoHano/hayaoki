# frozen_string_literal: true

require_relative "rule_helper"
require "hayate/boot_report/rules/tzinfo_eager_load"

class TzinfoEagerLoadTest < Minitest::Test
  include RuleHelper

  def ns(name, ms) = { "name" => name, "inclusive_ms" => st(ms), "self_ms" => st(ms), "owner" => "tzinfo", "category" => "gem" }

  def test_suggests_when_tzinfo_eager_load_is_slow
    r = make_report(eager_namespaces: [ns("ActionView.eager_load!", 30.0), ns("TZInfo.eager_load!", 240.0)])
    s = run_rule(B::Rules::TzinfoEagerLoad, r, app_dir: nil)
    assert_equal 1, s.size
    assert_equal :medium, s.first.confidence
    assert_in_delta 240.0, s.first.estimated_savings_ms, 1e-6
    assert_includes s.first.action, "eager_load_namespaces.delete(TZInfo)"
    assert_includes s.first.action, "preload_app!"
  end

  def test_silent_below_threshold_or_missing
    assert_empty run_rule(B::Rules::TzinfoEagerLoad, make_report(eager_namespaces: [ns("TZInfo.eager_load!", 5.0)]), app_dir: nil)
    assert_empty run_rule(B::Rules::TzinfoEagerLoad, make_report, app_dir: nil)
  end

  def test_overlaps_with_eager_load_tradeoff
    r = make_report(phases: { "boot" => st(1000.0), "total" => st(1040.0), "eager_load" => st(400.0) },
                    eager_namespaces: [ns("TZInfo.eager_load!", 240.0)])
    list = B::Advisor.new(r, app_dir: nil, rules: [B::Rules::EagerLoadTradeoff, B::Rules::TzinfoEagerLoad]).suggestions
    tz = list.find { _1.rule == :tzinfo_eager_load }
    refute_nil tz
    assert_includes tz.overlaps, "eager_load_tradeoff"
  end
end
