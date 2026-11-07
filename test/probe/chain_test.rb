# frozen_string_literal: true

require "test_helper"

# alias chain の共存: 後から別のライブラリが require を alias_method で退避・上書きしても boot が壊れず、
# どのラッパーも期待どおり呼ばれ、probe は require を1回だけ記録する (§8.2 の5通り)
class ProbeChainTest < Minitest::Test
  include ProbeHelper

  CHAIN = File.join(FIXTURES, "chain")
  PROBE_Q = PROBE.dump

  # chain_a は Kernel#require、chain_b は Kernel.require で読む。
  # bootsnap 相当は instance のみなので、singleton 経路には現れない (設計書 A-4)。
  EXPECTED = {
    %w[bundled_gems chain_a] => 1, %w[bootsnap chain_a] => 1, %w[zeitwerk chain_a] => 1,
    %w[bundled_gems chain_b] => 1, %w[zeitwerk chain_b] => 1,
  }.freeze

  def chain_run(code, **opts)
    r = run_probe("require 'chain_libs'\n#{code}\nChainLibs.report", chdir: CHAIN, ruby_args: ["-I#{CHAIN}", *opts.delete(:ruby_args).to_a], **opts)
    assert_predicate r.status, :success?, r.err
    r
  end

  def calls(r)
    r.out.lines.grep(/\A\w+ chain_\w+ \d+\n\z/).to_h { |l| *k, n = l.split; [k, n.to_i] }
  end

  def assert_recorded_once(rep)
    %w[chain_a chain_b].each do |t|
      assert_equal 1, rep.feature("/#{t}.rb").size, "#{t}.rb recorded exactly once"
    end
    assert_equal "ok", rep["status"]
  end

  def test_order_1_probe_first_then_libs
    r = chain_run("ChainLibs.install_real_order; require 'chain_a'; Kernel.require 'chain_b'; p $chain_loaded")
    assert_equal EXPECTED, calls(r)
    assert_includes r.out, "[:a, :b]"
    assert_recorded_once(r.report)
    assert_empty r.err
  end

  def test_order_2_libs_first_then_probe_last
    code = "ChainLibs.install_real_order; load #{PROBE_Q}; require 'chain_a'; Kernel.require 'chain_b'; p $chain_loaded"
    r = chain_run(code, probe_args: [])
    assert_equal EXPECTED, calls(r)
    assert_includes r.out, "[:a, :b]"
    assert_recorded_once(r.report)
  end

  def test_order_3_prepend_by_another_library
    r = chain_run("ChainLibs.install_real_order; ChainLibs.prepend_like; require 'chain_a'; Kernel.require 'chain_b'; p $chain_loaded")
    c = calls(r)
    assert_equal EXPECTED.merge(%w[prepend chain_a] => 1, %w[prepend chain_b] => 1), c
    assert_includes r.out, "[:a, :b]"
    assert_recorded_once(r.report)
  end

  def test_order_3b_prepend_only
    r = chain_run("ChainLibs.prepend_like; require 'chain_a'; Kernel.require 'chain_b'")
    assert_equal({ %w[prepend chain_a] => 1, %w[prepend chain_b] => 1 }, calls(r))
    assert_recorded_once(r.report)
  end

  def test_order_4_disable_gems_then_rubygems_loaded_later
    code = "require 'rubygems'; require 'chain_a'; Kernel.require 'chain_b'; p defined?(Gem::Specification), $chain_loaded"
    r = chain_run(code, ruby_args: ["--disable-gems"])
    assert_includes r.out, "[:a, :b]"
    assert_includes r.out, "\"constant\""
    rep = r.report
    assert_recorded_once(rep)
    assert_equal 1, rep.feature("/rubygems.rb").size
  end

  def test_order_5_probe_loaded_twice
    r = chain_run("ChainLibs.install_real_order; load #{PROBE_Q}; require 'chain_a'; Kernel.require 'chain_b'",
                  probe_args: [PROBE, PROBE])
    assert_equal EXPECTED, calls(r)
    assert_recorded_once(r.report)
  end

  def test_no_redefinition_warning_from_probe_under_w
    r = run_probe("require './t_leaf'", ruby_args: ["-w"])
    refute_match(%r{hayate/probe\.rb.*redefined}, r.err)
    assert_equal "ok", r.report["status"]
  end

  def test_kernel_is_never_prepended_and_helpers_are_private
    code = <<~'RUBY'
      p Kernel.ancestors.first == Kernel
      p Kernel.singleton_class.ancestors.first == Kernel.singleton_class
      p %i[require load require_relative __hayate_require __hayate_load __hayate_require_relative].map { |m| Kernel.private_method_defined?(m) }
      p Kernel.respond_to?(:require), Kernel.respond_to?(:load)
      p Kernel.singleton_class.private_method_defined?(:__hayate_require)
      p ENV.key?("HAYATE_PROBE_OUT"), ENV.key?("HAYATE_SPAWN_AT")
      p $LOADED_FEATURES.grep(/json/).empty?
    RUBY
    r = run_probe(code, env: { "HAYATE_SPAWN_AT" => "123.5" })
    assert_equal ["true", "true", "[true, true, true, true, true, true]", "true", "true", "true", "false", "false", "true"], r.out.lines.map(&:strip).flat_map { |l| l.start_with?("[") ? [l] : l.split(", ") }
    assert_equal "123.5", r.report["spawn_at"]
  end

  def test_only_one_probe_frame_is_added_to_the_backtrace
    # ネイティブの require / load のフレーム数に対して、probe が増やすのは1フレームだけ
    {"require './t_frames'" => "require", "load './t_frames.rb'" => "load"}.each do |code, what|
      native = run_probe(code, probe_args: []).out.strip.to_i
      with = run_probe(code).out.strip.to_i
      assert_operator native, :>=, 1
      assert_equal native + 1, with, "#{what}: one extra frame"
    end
  end
end
