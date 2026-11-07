# frozen_string_literal: true

require "test_helper"
require "stringio"
require "hayate/cli"

class HayateCLITest < Minitest::Test
  def cli
    @out = StringIO.new
    @err = StringIO.new
    Hayate::CLI.new(stdout: @out, stderr: @err)
  end

  def test_parse_defaults
    opts, dir = cli.parse([])
    assert_equal Dir.pwd, dir
    assert_equal 5, opts[:runs]
    assert_equal :warm, opts[:bootsnap]
    assert_equal "text", opts[:format]
    assert_equal 10, opts[:top]
  end

  def test_parse_all_options
    opts, dir = cli.parse(%w[--runs 3 --env test --bootsnap both --ruby /x/ruby --entry c/e --timeout 9 --format json --output o.json --top 4 app])
    assert_equal "app", dir
    assert_equal({ runs: 3, env: "test", bootsnap: :both, ruby: "/x/ruby", entry: "c/e", timeout: 9.0, format: "json", output: "o.json", top: 4 },
                 opts.reject { |k, _| k == :action })
  end

  def test_invalid_options
    c = cli
    assert_equal 1, c.run(%w[boot-report --bootsnap hot])
    assert_match(/invalid argument/, @err.string)
    assert_equal 1, c.run(%w[boot-report --runs 0])
    assert_equal 1, c.run(%w[nope])
  end

  def test_help_and_version
    c = cli
    assert_equal 0, c.run(%w[boot-report --help])
    assert_includes @out.string, "--bootsnap"
    assert_includes @out.string, "--format"
    c = cli
    assert_equal 0, c.run(%w[--version])
    assert_equal "hayate #{Hayate::VERSION}\n", @out.string
  end

  def test_missing_app_dir
    c = cli
    assert_equal 1, c.run(%w[boot-report /nonexistent/zzz])
    assert_match(/not found/, @err.string)
  end

  def test_integration_rails_min
    skip "rails is not installed" unless %w[rails zeitwerk].all? { !Gem::Specification.find_all_by_name(_1).empty? }
    require "hayate/boot_report/runner"
    require_relative "runner_test" unless defined?(BootReportRunnerTest)
    dir = BootReportRunnerTest.prepare_app
    skip "bundle lock failed" if BootReportRunnerTest.lock_error
    c = cli
    code = c.run(["boot-report", "--runs", "1", "--bootsnap", "warm", "--ruby", RbConfig.ruby, dir])
    assert_equal 0, code, @err.string
    assert_includes @out.string, "Phases"
    assert_match(/run 1\/1/, @err.string)
  end

  def test_bad_ruby_gives_short_message
    dir = Dir.mktmpdir("hayate-cli")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "ok.rb"), "")
    assert_equal 1, cli.run(["boot-report", "--ruby", "/nonexistent/ruby", "--entry", "ok.rb", "--runs", "1", dir])
    assert_match(/--ruby/, @err.string)
    refute_match(/\.rb:\d+:in/, @err.string)
  end

  def test_unwritable_output
    dir = Dir.mktmpdir("hayate-cli")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "ok.rb"), "")
    assert_equal 1, cli.run(["boot-report", "--runs", "1", "--entry", "ok.rb", "--ruby", RbConfig.ruby, "--output", File.join(dir, "no/such/dir/o.txt"), dir])
    assert_match(/cannot write/, @err.string)
  end

  def test_production_secret_hint
    dir = Dir.mktmpdir("hayate-cli")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "boom.rb"), "raise 'Missing secret_key_base for production'\n")
    assert_equal 1, cli.run(["boot-report", "--runs", "1", "--entry", "boom.rb", "--ruby", RbConfig.ruby, dir])
    assert_includes @err.string, "SECRET_KEY_BASE_DUMMY=1"
    assert_includes @err.string, "--env"
    assert_includes @err.string, "external services"
  end
end
