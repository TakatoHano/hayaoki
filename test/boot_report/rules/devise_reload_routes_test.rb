# frozen_string_literal: true

require_relative "rule_helper"
require "hayaoki/boot_report/rules/devise_reload_routes"

class DeviseReloadRoutesTest < Minitest::Test
  include RuleHelper

  def hook(ms, source: "/gems/devise-5.0.4/lib/devise/rails.rb:16")
    { "name" => "before_eager_load", "source" => source, "inclusive_ms" => st(ms), "self_ms" => st(1.0) }
  end

  def result(version) = { "payloads" => { "warm" => [{ "specs" => { "devise" => [version, "/gems/devise-#{version}", nil] } }] } }

  def test_medium_on_devise_5
    s = run_rule(B::Rules::DeviseReloadRoutes, make_report(on_loads: [hook(290.0)]), app_dir: nil, result: result("5.0.4"))
    assert_equal 1, s.size
    assert_equal :medium, s.first.confidence
    assert_in_delta 290.0, s.first.estimated_savings_ms, 1e-6
    assert_includes s.first.action, "config.reload_routes = false"
    assert_equal "5.0.4", s.first.evidence.first["devise"]
  end

  def test_low_with_caveat_on_devise_4
    s = run_rule(B::Rules::DeviseReloadRoutes, make_report(on_loads: [hook(290.0)]), app_dir: nil, result: result("4.9.4"))
    assert_equal :low, s.first.confidence
    assert_includes s.first.action, "Devise 5.0+ removes this risk"
  end

  def test_silent_when_fast_or_other_hook
    assert_empty run_rule(B::Rules::DeviseReloadRoutes, make_report(on_loads: [hook(10.0)]), app_dir: nil, result: result("5.0.4"))
    other = hook(300.0, source: "/gems/foo/lib/foo/railtie.rb:3")
    assert_empty run_rule(B::Rules::DeviseReloadRoutes, make_report(on_loads: [other]), app_dir: nil, result: result("5.0.4"))
  end
end
