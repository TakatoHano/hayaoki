# frozen_string_literal: true

require_relative "rule_helper"

class EagerLoadTradeoffTest < Minitest::Test
  include RuleHelper
  K = B::Rules::EagerLoadTradeoff

  def report(eager, boot = 1000.0) = make_report(phases: { "boot" => st(boot), "eager_load" => eager && st(eager) })

  def test_info_when_ratio_high
    s = run_rule(K, report(200.0), app_dir: Dir.tmpdir).fetch(0)
    assert_equal :info, s.confidence
    assert_includes s.title, "20.0%"
    assert_includes s.action, "first"
  end

  def test_silent_when_low_or_missing
    assert_empty run_rule(K, report(100.0), app_dir: Dir.tmpdir)
    assert_empty run_rule(K, report(nil), app_dir: Dir.tmpdir)
  end

  def test_boundary_inclusive
    assert_equal 1, run_rule(K, report(150.0), app_dir: Dir.tmpdir).size
  end
end
