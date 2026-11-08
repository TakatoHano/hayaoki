# frozen_string_literal: true

require_relative "rule_helper"
require "hayaoki/boot_report/rules/controller_action_methods"

class ControllerActionMethodsTest < Minitest::Test
  include RuleHelper

  def ns(name, ms) = { "name" => name, "inclusive_ms" => st(ms), "self_ms" => st(ms), "owner" => "actionpack", "category" => "gem" }

  def test_low_suggestion_when_slow
    s = run_rule(B::Rules::ControllerActionMethods, make_report(eager_namespaces: [ns("AbstractController.eager_load!", 450.0)]), app_dir: nil)
    assert_equal 1, s.size
    assert_equal :low, s.first.confidence
    assert_includes s.first.action, "eager_load_namespaces.delete(AbstractController)"
  end

  def test_silent_below_threshold
    assert_empty run_rule(B::Rules::ControllerActionMethods, make_report(eager_namespaces: [ns("AbstractController.eager_load!", 30.0)]), app_dir: nil)
  end

  def test_overlaps_with_eager_load_tradeoff
    r = make_report(phases: { "boot" => st(1000.0), "total" => st(1040.0), "eager_load" => st(600.0) },
                    eager_namespaces: [ns("AbstractController.eager_load!", 450.0)])
    list = B::Advisor.new(r, app_dir: nil, rules: [B::Rules::EagerLoadTradeoff, B::Rules::ControllerActionMethods]).suggestions
    assert_includes list.find { _1.rule == :controller_action_methods }.overlaps, "eager_load_tradeoff"
  end
end
