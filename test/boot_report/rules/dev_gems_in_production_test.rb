# frozen_string_literal: true

require_relative "rule_helper"

class DevGemsInProductionTest < Minitest::Test
  include RuleHelper
  K = B::Rules::DevGemsInProduction

  def test_detects_and_sums
    r = make_report(gems: [gem_row("pry-rails", 12.0), gem_row("rspec-core", 8.5), gem_row("pg", 3.0), gem_row("faker", 20)])
    s = run_rule(K, r, app_dir: Dir.tmpdir).fetch(0)
    assert_equal :dev_gems_in_production, s.rule
    assert_equal :high, s.confidence
    assert_in_delta 40.5, s.estimated_savings_ms
    assert_equal %w[faker pry-rails rspec-core], s.evidence.map { _1["name"] }
    assert_includes s.action, "group :development, :test"
  end

  def test_none_when_no_dev_gems
    assert_empty run_rule(K, make_report(gems: [gem_row("rails", 50), gem_row("pg", 3)]), app_dir: Dir.tmpdir)
  end

  def test_ignored_in_development_env_and_for_app_category
    r = make_report(gems: [gem_row("pry", 5)], meta: { "env" => "development" })
    assert_empty run_rule(K, r, app_dir: Dir.tmpdir)
    r = make_report(gems: [gem_row("pry", 5, category: "app")])
    assert_empty run_rule(K, r, app_dir: Dir.tmpdir)
  end

  def test_symbol_keyed_hash_report
    sym = { gems: [{ name: "byebug", category: "gem", self_ms: { median: 4.0 } }], meta: { env: "production" } }
    s = run_rule(K, sym, app_dir: Dir.tmpdir)
    assert_equal 1, s.size
    assert_in_delta 4.0, s[0].estimated_savings_ms
  end
end
