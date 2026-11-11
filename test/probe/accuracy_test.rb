# frozen_string_literal: true

require "test_helper"

# 既知の sleep を持つダミー gem (fixtures/slowgem) と Rails の模造 (fixtures/fake_rails) で、
# 時間の帰属を検証する。期待値は sleep の指定値ではなくダミー内部で測った値 (macOS では sleep が平均 +4ms 延びる)。
class ProbeAccuracyTest < Minitest::Test
  include ProbeHelper

  TOL_MS = 2.0 * TIMING_SLACK

  CODE = <<~'RUBY'
    require "active_support/lazy_load_hooks"
    require "rails/initializable"
    require "zeitwerk/loader"
    require "rails/application"
    $hayaoki_measured = {}
    Rails::Application.initializers << [:spike_initializer, proc {
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep 0.02
      $hayaoki_measured[:init] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    }]
    require "slowgem"
    ActiveSupport.run_load_hooks(:action_controller)
    Rails::Application.new.initialize!
    Zeitwerk::Loader.new("rails.main").eager_load
    File.write(ENV.fetch("MEASURED"), $hayaoki_measured.map { |k, v| "#{k}=#{v}" }.join("\n"))
  RUBY

  def setup
    Dir.mktmpdir("hayaoki-acc") do |dir|
      mf = File.join(dir, "measured")
      @result = run_probe(
        CODE, chdir: FIXTURES, env: { "MEASURED" => mf },
        ruby_args: ["-I#{FIXTURES}/slowgem/lib", "-I#{FIXTURES}/fake_rails/lib"]
      )
      @measured = File.read(mf).lines.to_h { |l| k, v = l.strip.split("="); [k.to_sym, v.to_f * 1000] }
    end
    @rep = @result.report
    assert_equal "ok", @rep["status"], @result.err
  end

  def assert_close(expected_ms, actual_ms, label)
    assert_in_delta expected_ms, actual_ms, TOL_MS, "#{label}: expected #{expected_ms.round(2)}ms, got #{actual_ms.round(2)}ms"
  end

  def test_gem_files_get_their_own_self_time
    slowgem = @rep.feature("/slowgem.rb")
    assert_equal 1, slowgem.size
    assert_close @measured[:slowgem], slowgem.first.self_ms, "slowgem.rb self"

    inner = @rep.feature("/slowgem/inner.rb")
    assert_equal 1, inner.size, "inner is recorded once"
    assert_equal ProbeReport::K_RR, inner.first.kind, "recorded as require_relative"
    assert_equal slowgem.first.idx, inner.first.parent
    assert_close @measured[:inner], inner.first.self_ms, "inner"

    other = @rep.feature("/slowgem/other.rb")
    assert_equal 1, other.size
    assert_equal ProbeReport::K_REQ, other.first.kind
    assert_close @measured[:other], other.first.self_ms, "other"
  end

  def test_slowgem_inclusive_time_is_sum_of_its_parts
    s = @rep.feature("/slowgem.rb").first
    total = @measured.values_at(:slowgem, :inner, :other).sum
    # 内側の require 自体 (ファイル探索と読み込み) のぶんだけ測った値の合計を上回る
    assert_operator s.dur_ms, :>=, total
    assert_operator s.dur_ms, :<, total + 10 * TIMING_SLACK
  end

  def test_on_load_is_attributed_to_the_block_owner
    spans = @rep.named(ProbeReport::K_ONLOAD, "action_controller")
    assert_equal 1, spans.size
    span = spans.first
    assert_match(%r{/fixtures/slowgem/lib/slowgem\.rb:\d+\z}, span.res, "owner is found from source_location")
    assert_close @measured[:on_load], span.dur_ms, "on_load"
    hooks = @rep.named(ProbeReport::K_HOOKS, "action_controller")
    assert_equal 1, hooks.size
    assert_equal hooks.first.idx, span.parent, "on_load is nested under run_load_hooks"
    assert_close 0.0, hooks.first.self_ms, "run_load_hooks self time excludes the block"
  end

  def test_initializer_and_eager_load_spans
    init = @rep.named(ProbeReport::K_INIT, "spike_initializer")
    assert_equal 1, init.size
    assert_close @measured[:init], init.first.dur_ms, "initializer"
    assert_equal "Rails::Application", init.first.res[0]
    assert_match(/:\d+\z/, init.first.res[1])
    refute_nil init.first.cpu, "coarse spans record cpu time"
    assert_equal 1, @rep.named(ProbeReport::K_PHASE, "initialize").size
    assert_equal init.first.parent, @rep.named(ProbeReport::K_PHASE, "initialize").first.idx
    assert_equal 1, @rep.named(ProbeReport::K_EAGER, "rails.main").size
  end

  def test_lazy_install_leaves_only_missing_targets_pending
    # この fixture は Bundler と ActiveSupport::Deprecation を読まない
    assert_equal ["/active_support/deprecation/reporting.rb", "/bundler/runtime.rb"], @rep["pending_hooks"].sort
    assert_empty @rep["probe_errors"]
  end

  def test_timestamps_are_ordered_and_nested
    @rep.spans.each do |s|
      assert_operator s.t1, :>=, s.t0
      next if s.parent < 0
      p = @rep.spans.find { |x| x.idx == s.parent }
      assert_operator s.t0, :>=, p.t0
      assert_operator s.t1, :<=, p.t1
    end
  end
end
