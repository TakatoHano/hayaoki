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
      assert_includes s.title, "No references found to aws-sdk-s3"
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

  def test_constants_from_payload_are_used_for_search
    with_app("Gemfile" => %(gem "whatever"\n), "lib/a.rb" => "Zed::Thing\n") do
      assert_empty run_rule(K, report(gem_row("whatever", 50, constants: ["Zed"])))
      s = run_rule(K, report(gem_row("whatever", 50, constants: ["Nope"]))).fetch(0)
      assert_equal :low, s.confidence
    end
  end

  def test_apm_gems_are_excluded
    gems = %w[newrelic_rpm ddtrace datadog sentry-ruby sentry-rails scout_apm skylight honeybadger bugsnag rollbar
              appsignal opentelemetry-sdk opentelemetry-instrumentation-rails].map { gem_row(_1, 90) }
    with_app("Gemfile" => gems.map { %(gem "#{_1["name"]}"\n) }.join) do
      assert_empty run_rule(K, report(*gems))
    end
  end

  def test_railtie_gems_are_excluded_by_measured_hooks
    with_app("Gemfile" => %(gem "a"\ngem "b"\ngem "c"\n)) do
      gems = [gem_row("a", 90, "initializer_count" => st(1)), gem_row("b", 90, "on_load_ms" => st(2)), gem_row("c", 90)]
      assert_equal %w[c], run_rule(K, report(*gems)).map { _1.evidence[0]["gem"] }
    end
  end

  def test_railtie_gems_are_excluded_by_gem_files
    Dir.mktmpdir("fakegem") do |gdir|
      FileUtils.mkdir_p(File.join(gdir, "lib/foo"))
      File.write(File.join(gdir, "lib/foo/engine.rb"), "")
      spec = Struct.new(:full_gem_path).new(gdir)
      orig = Gem.method(:loaded_specs)
      Gem.define_singleton_method(:loaded_specs) { { "foo" => spec } }
      begin
        with_app("Gemfile" => %(gem "foo"\n)) { assert_empty run_rule(K, report(gem_row("foo", 90))) }
      ensure
        Gem.define_singleton_method(:loaded_specs, orig.unbind.bind(Gem))
      end
    end
  end

  def test_gemfile_require_string_means_used_under_other_name
    with_app("Gemfile" => %(gem "foo", require: "foo/bar"\ngem "baz", require: false\ngem "qux", require: true\n)) do
      assert_equal %w[qux], run_rule(K, report(gem_row("foo", 90), gem_row("baz", 90), gem_row("qux", 90))).map { _1.evidence[0]["gem"] }
    end
  end

  def test_dsl_names_count_as_reference
    with_app("Gemfile" => %(gem "paper_trail"\n), "app/models/a.rb" => "class A\n  has_paper_trail\nend\n") do
      assert_empty run_rule(K, report(gem_row("paper_trail", 90)))
    end
    with_app("Gemfile" => %(gem "paper_trail"\n), "app/models/a.rb" => "class A; end\n") do
      assert_equal 1, run_rule(K, report(gem_row("paper_trail", 90))).size
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

  def test_no_gemfile_means_no_suggestions
    with_app("app/models/user.rb" => "class User; end\n") do
      assert_empty run_rule(K, report(gem_row("aws-sdk-s3", 90)))
    end
  end

  def test_multi_segment_name_does_not_match_first_segment_only
    # Rack / Net / Google は多くのアプリに出てくるので rack-attack の参照とはみなさない
    with_app("Gemfile" => %(gem "rack-attack"\n), "app/a.rb" => "Rack::Request.new\n") do
      assert_equal 1, run_rule(K, report(gem_row("rack-attack", 50))).size
    end
    with_app("Gemfile" => %(gem "rack-attack"\n), "app/a.rb" => "Rack::Attack.throttle\n") do
      assert_empty run_rule(K, report(gem_row("rack-attack", 50)))
    end
  end

  def test_railtie_detected_from_child_payload_specs
    Dir.mktmpdir("hayate-gem") do |gdir|
      FileUtils.mkdir_p(File.join(gdir, "lib/foo"))
      File.write(File.join(gdir, "lib/foo/railtie.rb"), "")
      res = Struct.new(:payloads).new({ "warm" => [{ "status" => "ok", "specs" => { "foo_bar" => ["1.0", gdir, nil] } }] })
      with_app("Gemfile" => %(gem "foo_bar"\n), "app/a.rb" => "1\n") do
        assert_empty run_rule(K, report(gem_row("foo_bar", 50)), result: res)
        assert_equal 1, run_rule(K, report(gem_row("foo_bar", 50))).size
      end
    end
  end

  def test_gems_from_eval_gemfile_count_as_direct
    with_app("Gemfile" => %(eval_gemfile "gems/extra.gemfile"\n), "gems/extra.gemfile" => %(gem "foo_bar"\n), "app/a.rb" => "1\n") do
      assert_equal 1, run_rule(K, report(gem_row("foo_bar", 50))).size
    end
  end
end
