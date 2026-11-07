# frozen_string_literal: true

require_relative "rule_helper"

class DevGemsInProductionTest < Minitest::Test
  include RuleHelper
  K = B::Rules::DevGemsInProduction

  def test_direct_ungrouped_is_high_and_sums
    gemfile = %(gem "pry-rails"\ngem "rspec-core"\n)
    r = make_report(gems: [gem_row("pry-rails", 12.0), gem_row("rspec-core", 8.5), gem_row("pg", 3.0)])
    with_app("Gemfile" => gemfile) do
      s = run_rule(K, r).fetch(0)
      assert_equal :dev_gems_in_production, s.rule
      assert_equal :high, s.confidence
      assert_in_delta 20.5, s.estimated_savings_ms
      assert_equal %w[pry-rails rspec-core], s.evidence.map { _1["name"] }
      assert_includes s.action, "group :development, :test"
    end
  end

  def test_transitive_is_low_and_factory_gems_are_medium
    gemfile = %(gem "faker"\ngem "factory_bot_rails"\ngem "rails"\n)
    r = make_report(gems: [gem_row("faker", 20), gem_row("factory_bot_rails", 10), gem_row("pry", 5), gem_row("pg", 3)])
    with_app("Gemfile" => gemfile) do
      s = run_rule(K, r)
      assert_equal %i[medium low], s.map(&:confidence)
      assert_equal %w[faker factory_bot_rails], s[0].evidence.map { _1["name"] }
      assert_equal %w[pry], s[1].evidence.map { _1["name"] }
    end
  end

  def test_gems_in_dev_test_groups_are_not_flagged
    gemfile = <<~G
      gem "rails"
      group :development, :test do
        gem "pry-rails"
        platforms :mri do
          gem "byebug"
        end
      end
      group :test do
        gem "capybara"
      end
      gem "faker", group: :development
      gem "rspec-core", groups: [:development, :test]
      gem "bullet", :group => "test"
      gem "listen"
    G
    names = %w[pry-rails byebug capybara faker rspec-core bullet listen]
    with_app("Gemfile" => gemfile) do
      s = run_rule(K, make_report(gems: names.map { gem_row(_1, 5) }))
      assert_equal [%w[listen]], s.map { |x| x.evidence.map { _1["name"] } }
      assert_equal :high, s[0].confidence
    end
  end

  def test_gem_in_production_group_is_high
    with_app("Gemfile" => %(group :development, :production do\n  gem "listen"\nend\n)) do
      assert_equal :high, run_rule(K, make_report(gems: [gem_row("listen", 5)])).fetch(0).confidence
    end
  end

  def test_no_gemfile_is_low
    s = run_rule(K, make_report(gems: [gem_row("pry", 5)]), app_dir: Dir.tmpdir).fetch(0)
    assert_equal :low, s.confidence
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
    with_app("Gemfile" => %(gem "byebug"\n)) do
      s = run_rule(K, sym)
      assert_equal 1, s.size
      assert_equal :high, s[0].confidence
    end
    s = run_rule(K, sym, app_dir: Dir.tmpdir)
    assert_equal 1, s.size
    assert_in_delta 4.0, s[0].estimated_savings_ms
  end
end
