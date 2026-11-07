# frozen_string_literal: true

require "test_helper"
require "hayate/boot_report/runner"
require "hayate/boot_report/aggregator"

class BootReportRunnerTest < Minitest::Test
  class << self
    attr_reader :app_dir, :lock_error

    def rails_available?
      %w[rails zeitwerk].all? { !Gem::Specification.find_all_by_name(_1).empty? }
    end

    # fixture アプリを tmp に複製し、ローカルの gem だけで Gemfile.lock を作る (1 回だけ)
    def prepare_app
      return @app_dir if @app_dir
      @app_dir, @lock_error = prepare_rails_min_app("hayate-runner")
      @app_dir
    end
  end

  def prepare_rails
    skip "rails is not installed" unless self.class.rails_available?
    dir = self.class.prepare_app
    skip "bundle lock --local failed: #{self.class.lock_error.to_s[0, 300]}" if self.class.lock_error
    dir
  end

  def test_rails_min_warm_and_cold
    skip "bootsnap is not installed" if Gem::Specification.find_all_by_name("bootsnap").empty?
    dir = prepare_rails
    result = Hayate::BootReport::Runner.new(app_dir: dir, runs: 4, bootsnap: :both).run
    assert_equal %w[warm cold], result.conditions
    assert_empty result.meta["warnings"]
    reports = Hayate::BootReport::Aggregator.new.aggregate_result(result)

    %w[warm cold].each do |cond|
      payloads = result.payloads[cond.to_s]
      assert_equal 4, payloads.size
      payloads.each do |p|
        assert_equal "ok", p["status"], cond
        assert_equal dir, p["rails_root"]
      end
      rep = reports[cond]
      assert_equal 4, rep.runs, cond
      slow = rep.gems.find { _1["name"] == "slowgem" }
      refute_nil slow, "slowgem is attributed in #{cond}: #{rep.gems.map { _1["name"] }.first(8)}"
      assert_operator slow["self_ms"]["median"], :>=, 170, cond # 100 + 50 + 30 - 誤差
      assert_equal "gem", slow["category"]
      assert_equal "slowgem", rep.on_loads.find { _1["source"].to_s.include?("slowgem") }["owner"]
      assert_equal "app", rep.gems.find { _1["name"] == "app" }["name"]
      refute_nil rep.phases["initialize"]
      refute_nil rep.phases["bundler_require"]
      assert_operator rep.phases["total"]["median"], :>, 0
      assert_operator rep.phases["vm_boot"]["median"], :>, 0
      ov = result.meta["overhead"][cond]
      assert_kind_of Numeric, ov["baseline_ms"]
      assert_kind_of Numeric, ov["diff_ms"]
      assert_kind_of Numeric, ov["ratio"]
      assert_operator ov["baseline_ms"], :>, 0
      # 1 回ごとのノイズ (±15〜20ms) があるので、基準の ±10% 程度の範囲で「極端な値でないこと」だけを見る
      tol = [ov["baseline_ms"] * 0.1, 30.0].max * TIMING_SLACK
      assert_in_delta 0, ov["diff_ms"], tol, "#{cond} overhead diff #{ov["diff_ms"]}"
      JSON.generate(rep.to_h)
    end
  end

  def test_failing_entry_returns_error_with_stderr_tail
    dir = Dir.mktmpdir("hayate-fail")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "boom.rb"), "require 'set'\nwarn 'about to fail'\nraise 'boom from entry'\n")
    runner = Hayate::BootReport::Runner.new(app_dir: dir, runs: 1, entry: "boom.rb", bootsnap: :warm, timeout: 60)
    err = assert_raises(Hayate::BootReport::RunError) { runner.run }
    assert_equal :boot_error, err.reason
    assert_includes err.stderr_tail, "boom from entry"
    assert_includes err.message, "boom from entry"
    assert_equal "error", err.partial["status"], "partial result with status=error"
    assert_equal "RuntimeError", err.probe_error["class"]
    assert_equal "boom.rb", File.basename(err.open_span["name"]), "last open span is the entry"
  end

  def test_on_progress_events
    dir = Dir.mktmpdir("hayate-prog")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "ok.rb"), "require 'set'\n")
    events = []
    Hayate::BootReport::Runner.new(app_dir: dir, runs: 2, entry: "ok.rb", on_progress: ->(e) { events << e }).run
    assert_equal %i[warmup probe baseline probe baseline], events.map { _1["phase"] }
    assert_equal [0, 1, 1, 2, 2], events.map { _1["index"] }
    assert(events.all? { _1["bootsnap"] == :warm && _1["total"] == 2 })
  end

  def test_timeout_kills_child_and_reports
    dir = Dir.mktmpdir("hayate-timeout")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "slow.rb"), "warn 'started'\nsleep 30\n")
    runner = Hayate::BootReport::Runner.new(app_dir: dir, runs: 1, entry: "slow.rb", timeout: 1)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = assert_raises(Hayate::BootReport::RunError) { runner.run }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 15
    assert_equal :timeout, err.reason
    assert_includes err.stderr_tail, "started"
  end

  def test_no_output_when_child_exits_with_exit_bang
    dir = Dir.mktmpdir("hayate-exitbang")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "bye.rb"), "warn 'bye'\nexit!(0)\n")
    err = assert_raises(Hayate::BootReport::RunError) do
      Hayate::BootReport::Runner.new(app_dir: dir, runs: 1, entry: "bye.rb").run
    end
    assert_equal :no_output, err.reason
    assert_includes err.stderr_tail, "bye"
  end

  def test_command_shape
    r = Hayate::BootReport::Runner.new(app_dir: "/tmp", entry: "config/environment")
    cmd = r.command
    assert_equal ["ruby", "-r", Hayate::BootReport::PROBE_PATH, "-e"], cmd.first(4)
    assert_equal 'require File.expand_path("config/environment", Dir.pwd)', cmd.last
    assert_equal 3, r.command(probe: false).size
  end

  def test_partial_failure_is_recorded_and_run_continues
    dir = Dir.mktmpdir("hayate-partial")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    counter = File.join(dir, "count")
    # n は probe 有りの実行 (warmup=1, 計測=2..4) の通し番号。3 回目だけ失敗する
    File.write(File.join(dir, "flaky.rb"), <<~RUBY)
      unless ENV["HAYATE_BASE_MARK"]
        n = (File.exist?(#{counter.inspect}) ? File.read(#{counter.inspect}).to_i : 0) + 1
        File.write(#{counter.inspect}, n.to_s)
        raise "flaky \#{n}" if n == 3
      end
    RUBY
    result = Hayate::BootReport::Runner.new(app_dir: dir, runs: 3, entry: "flaky.rb").run
    failed = result.meta["failed_runs"]
    assert_equal 1, failed.size
    assert_equal "boot_error", failed[0]["reason"]
    assert_includes failed[0]["stderr_tail"], "flaky 3"
    list = result.payloads["warm"]
    assert_equal 3, list.size
    assert_equal 2, list.count { _1["status"] == "ok" }
    rep = Hayate::BootReport::Aggregator.new.aggregate_result(result)["warm"]
    assert_equal 2, rep.runs
    assert_equal 1, rep.failed
  end

  def test_all_runs_failing_raises
    dir = Dir.mktmpdir("hayate-allfail")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "boom.rb"), "raise 'always'\n")
    assert_raises(Hayate::BootReport::RunError) { Hayate::BootReport::Runner.new(app_dir: dir, runs: 2, entry: "boom.rb").run }
  end

  def test_missing_lockfile_is_reported_before_start_and_not_created
    dir = Dir.mktmpdir("hayate-nolock")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\n")
    File.write(File.join(dir, "ok.rb"), "")
    err = assert_raises(Hayate::BootReport::RunError) { Hayate::BootReport::Runner.new(app_dir: dir, entry: "ok.rb").run }
    assert_equal :no_lockfile, err.reason
    assert_includes err.message, "bundle lock"
    refute File.exist?(File.join(dir, "Gemfile.lock"))
  end

  def test_bundle_env_of_user_is_kept_and_frozen_is_passed
    dir = Dir.mktmpdir("hayate-env")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    File.write(File.join(dir, "Gemfile"), "")
    File.write(File.join(dir, "Gemfile.lock"), "")
    File.write(File.join(dir, "env.rb"), "File.write('env.out', ENV.values_at('BUNDLE_WITHOUT', 'BUNDLE_FROZEN', 'BUNDLE_BIN_PATH').inspect)\n")
    old = ENV["BUNDLE_WITHOUT"]
    ENV["BUNDLE_WITHOUT"] = "development"
    begin
      Hayate::BootReport::Runner.new(app_dir: dir, runs: 1, entry: "env.rb").run
    ensure
      ENV["BUNDLE_WITHOUT"] = old
    end
    assert_equal '["development", "true", nil]', File.read(File.join(dir, "env.out"))
  end

  def test_interrupt_signal_kills_child_group
    dir = Dir.mktmpdir("hayate-int")
    Minitest.after_run { FileUtils.rm_rf(dir) }
    pidfile = File.join(dir, "pid")
    File.write(File.join(dir, "sleepy.rb"), "File.write(#{pidfile.inspect}, Process.pid.to_s)\nsleep 60\n")
    got = nil
    old = Signal.trap("TERM") { got = :term }
    begin
      killer = Thread.new do
        sleep 0.05 until File.exist?(pidfile) && !File.read(pidfile).empty?
        Process.kill("TERM", Process.pid)
      end
      err = assert_raises(Hayate::BootReport::RunError) do
        Hayate::BootReport::Runner.new(app_dir: dir, runs: 1, entry: "sleepy.rb", timeout: 60).run
      end
      killer.join
      assert_equal :interrupted, err.reason
      assert_equal :term, got, "original TERM handler is restored and called"
    ensure
      Signal.trap("TERM", old)
    end
    pid = File.read(pidfile).to_i
    gone = begin
      Process.kill(0, pid)
      false
    rescue Errno::ESRCH
      true
    end
    assert gone, "child process #{pid} must not survive"
  end
end
