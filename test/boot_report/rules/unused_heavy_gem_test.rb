# frozen_string_literal: true

require_relative "rule_helper"

class UnusedHeavyGemTest < Minitest::Test
  include RuleHelper
  K = B::Rules::UnusedHeavyGem

  def report(*gems) = make_report(gems: gems)

  def test_reports_unreferenced_gem_as_low
    with_app("Gemfile" => %(gem "aws-sdk-s3"\n), "app/models/user.rb" => "class User; end\n",
             "lib/tasks/x.rake" => "puts 1\n") do
      s = run_rule(K, report(gem_row("aws-sdk-s3", 90))).fetch(0)
      assert_equal :low, s.confidence
      assert_in_delta 90.0, s.estimated_savings_ms
      assert_includes s.action, 'gem "aws-sdk-s3", require: false'
      assert_includes s.title, "may be unused"
    end
  end

  def test_not_reported_when_constant_referenced
    with_app("Gemfile" => %(gem "aws-sdk-s3"\n),
             "app/services/up.rb" => "class Up; def c = Aws::S3::Client.new; end\n") do
      assert_empty run_rule(K, report(gem_row("aws-sdk-s3", 90)))
    end
  end

  def test_not_reported_when_referenced_in_config_or_erb
    with_app("Gemfile" => %(gem "redcarpet"\ngem "rest-client"\n),
             "config/initializers/md.rb" => "Redcarpet::Markdown\n",
             "app/views/a.html.erb" => "<%= RestClient.get('x') %>\n") do
      assert_empty run_rule(K, report(gem_row("redcarpet", 50), gem_row("rest-client", 50)))
    end
  end

  def test_camelized_and_require_string_references
    with_app("Gemfile" => %(gem "foo_bar"\ngem "baz-qux"\n),
             "lib/a.rb" => "FooBar.run\n", "app/b.rb" => "require 'baz-qux'\n") do
      assert_empty run_rule(K, report(gem_row("foo_bar", 50), gem_row("baz-qux", 50)))
    end
  end

  def test_constant_prefix_does_not_count_as_reference
    # FooBarBaz は FooBar の参照ではない
    with_app("Gemfile" => %(gem "foo_bar"\n), "lib/a.rb" => "FooBarBaz.run\n") do
      assert_equal 1, run_rule(K, report(gem_row("foo_bar", 50))).size
    end
  end

  def test_constants_from_payload_are_medium_and_used
    with_app("lib/a.rb" => "Zed::Thing\n") do
      assert_empty run_rule(K, report(gem_row("whatever", 50, constants: ["Zed"])))
      s = run_rule(K, report(gem_row("whatever", 50, constants: ["Nope"]))).fetch(0)
      assert_equal :medium, s.confidence
    end
  end

  def test_exclusions_and_thresholds
    with_app("Gemfile" => "") do
      gems = %w[railties activesupport bootsnap zeitwerk bundler puma pry].map { gem_row(_1, 500) }
      assert_empty run_rule(K, report(*gems))
      assert_empty run_rule(K, report(gem_row("slowthing", 30)))   # threshold は超過のみ
    end
    with_app("Gemfile" => %(gem "slowthing"\n)) do
      assert_equal 1, run_rule(K, report(gem_row("slowthing", 31))).size
      assert_empty run_rule(K, report(gem_row("slowthing", 31)), gem: 40)
    end
  end

  def test_transitive_and_already_lazy_gems_are_skipped
    with_app("Gemfile" => %(gem "parent"\ngem "lazy", require: false\n)) do
      assert_empty run_rule(K, report(gem_row("child", 90), gem_row("lazy", 90)))
    end
  end

  def test_symbol_keyed_report
    with_app("Gemfile" => %(gem "slowthing"\n)) do
      r = { gems: [{ name: "slowthing", category: "gem", self_ms: { median: 99.0 } }] }
      assert_equal 1, run_rule(K, r).size
    end
  end

  def test_many_files_scan_is_fast
    files = (0...1500).to_h { |i| ["app/models/m#{i}.rb", "class M#{i}\n  def x = #{"foo(1, 2) " * 30}\nend\n"] }
    files["Gemfile"] = %(gem "slowthing"\n)
    with_app(files) do
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal 1, run_rule(K, report(gem_row("slowthing", 90))).size
      ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
      assert_operator ms, :<, 1500, "scan took #{ms.round}ms"
    end
  end
end
