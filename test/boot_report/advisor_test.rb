# frozen_string_literal: true

require_relative "rules/rule_helper"

class AdvisorTest < Minitest::Test
  include RuleHelper

  class Boom < B::Rules::Base
    def call = raise("kaboom")
  end

  def test_runs_all_rules_sorted_by_confidence
    with_app("Gemfile" => %(gem "slowthing"\n)) do |dir|
      r = make_report(
        gems: [gem_row("pry", 10), gem_row("slowthing", 80)],
        phases: { "boot" => st(1000.0), "eager_load" => st(300.0) },
        initializers: [{ "name" => "x", "context" => nil, "inclusive_ms" => st(90), "self_ms" => st(90), "category" => "app" }]
      )
      a = B::Advisor.new(r, app_dir: dir)
      confs = a.suggestions.map(&:confidence)
      assert_equal confs.sort_by { %i[high medium low info].index(_1) }, confs
      assert_equal %i[bootsnap_ineffective dev_gems_in_production heavy_app_initializer unused_heavy_gem eager_load_tradeoff].sort,
                   a.suggestions.map(&:rule).sort
      assert_empty a.warnings
    end
  end

  def test_rule_exception_becomes_warning
    with_app do |dir|
      a = B::Advisor.new(make_report(gems: [gem_row("pry", 10)]), app_dir: dir,
                         rules: [Boom, B::Rules::DevGemsInProduction])
      assert_equal [:dev_gems_in_production], a.suggestions.map(&:rule)
      assert_equal 1, a.warnings.size
      assert_match(/rule boom failed: RuntimeError: kaboom/, a.warnings[0])
    end
  end

  def test_thresholds_are_passed_through
    with_app("Gemfile" => %(gem "slowthing"\n)) do |dir|
      r = make_report(gems: [gem_row("slowthing", 80)])
      names = ->(**kw) { B::Advisor.new(r, app_dir: dir, **kw).suggestions.map(&:rule) }
      assert_includes names.call, :unused_heavy_gem
      refute_includes names.call(gem_threshold_ms: 100), :unused_heavy_gem
    end
  end

  def test_suggestion_to_h_has_string_keys
    with_app do |dir|
      h = B::Advisor.new(make_report(gems: [gem_row("pry", 10)]), app_dir: dir).suggestions.first.to_h
      assert_equal %w[action confidence estimated_savings_ms evidence rule title], h.keys.sort
      assert_kind_of String, h["rule"]
      JSON.generate(h)
    end
  end

  def test_text_and_json_integration
    require "hayate/boot_report/formatters/text"
    require "hayate/boot_report/formatters/json"
    with_app("Gemfile" => %(gem "slowthing"\n)) do |dir|
      r = make_report(gems: [gem_row("pry", 10), gem_row("slowthing", 80)])
      a = B::Advisor.new(r, app_dir: dir)
      out = B::Formatters::Text.new.with_suggestions(a.suggestions, ["! warn"]).format("warm" => r)
      assert_includes out, "Suggestions"
      assert_includes out, "[high]"
      assert_includes out, "[low]"
      assert out.lines.all? { _1.chomp.length <= 80 }, out.lines.reject { _1.chomp.length <= 80 }.inspect
      plain = B::Formatters::Text.new.format("warm" => r)
      refute_includes plain, "Suggestions"
      doc = JSON.parse(B::Formatters::Json.new.with_suggestions(a.suggestions, []).format("warm" => r))
      assert_equal a.suggestions.size, doc["suggestions"].size
      refute JSON.parse(B::Formatters::Json.new.format("warm" => r)).key?("suggestions")
    end
  end
end
