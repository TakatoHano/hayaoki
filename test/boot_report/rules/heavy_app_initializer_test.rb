# frozen_string_literal: true

require_relative "rule_helper"

class HeavyAppInitializerTest < Minitest::Test
  include RuleHelper
  K = B::Rules::HeavyAppInitializer

  def init(name, ms, cat) = { "name" => name, "context" => nil, "inclusive_ms" => st(ms), "self_ms" => st(ms), "category" => cat }

  def test_detects_heavy_app_initializer_and_file
    r = make_report(
      initializers: [init("my_app.warm_cache", 80, "app"), init("active_record.x", 300, "gem"), init("my_app.small", 10, "app")],
      files: [{ "path" => "/srv/app/config/initializers/aws.rb", "category" => "app", "inclusive_ms" => st(120), "self_ms" => st(5) }]
    )
    s = run_rule(K, r, app_dir: Dir.tmpdir).fetch(0)
    assert_equal :medium, s.confidence
    assert_equal ["config/initializers/aws.rb", "my_app.warm_cache"], s.evidence.map { _1["name"] }
    assert_in_delta 200.0, s.estimated_savings_ms
    assert_includes s.action, "after_initialize"
    assert_includes s.action, "ActiveSupport.on_load"
  end

  def test_threshold_is_configurable
    r = make_report(initializers: [init("a", 80, "app")])
    assert_empty run_rule(K, r, app_dir: Dir.tmpdir, init: 100)
    assert_equal 1, run_rule(K, r, app_dir: Dir.tmpdir, init: 70).size
  end

  def test_nothing_when_only_gem_initializers
    assert_empty run_rule(K, make_report(initializers: [init("x", 500, "gem")]), app_dir: Dir.tmpdir)
  end
end
