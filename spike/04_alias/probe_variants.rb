# frozen_string_literal: true
# Spike 4-2: require フックの方式比較 (実アプリで -r 読込)。HAYATE_V で方式を切替:
#   naive    : Kernel / Kernel.singleton_class に prepend し super で委譲
#   bindcall : 同上だが singleton は probe 読込時の元メソッドを bind_call (spike 02 の暫定策)
#   callee   : prepend + __callee__ != :require (alias 複製として呼ばれた) なら元メソッドを bind_call
#   chain    : prepend を使わず alias chain (alias_method + 再定義) で instance / singleton をフック
#   runtime  : instance だけ prepend(super)、singleton はフックせず Bundler::Runtime#require を包む
# 計測用に TracePoint で bootsnap / zeitwerk / bundled_gems の require ラッパーの呼出回数も数える。
module HayateSpike
  V = ENV.fetch("HAYATE_V", "chain")
  EV = []
  DEPTH = [0]
  ORIG_I = Kernel.instance_method(:require)
  ORIG_S = Kernel.method(:require).unbind
  def self.track(name)
    d = DEPTH[0]; DEPTH[0] = d + 1
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = yield
    EV << [name.to_s, r, d, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t] if r
    r
  ensure
    DEPTH[0] = d
  end

  module Hook
    def require(name)
      case V
      when "naive", "runtime" then HayateSpike.track(name) { super }
      when "bindcall"
        HayateSpike.track(name) { equal?(Kernel) ? ORIG_S.bind_call(Kernel, name) : super }
      when "callee"
        if __callee__ != :require
          (equal?(Kernel) ? ORIG_S : ORIG_I).bind_call(self, name)
        else
          HayateSpike.track(name) { super }
        end
      end
    end
  end

  case V
  when "naive", "bindcall", "callee"
    Kernel.prepend(Hook); Kernel.singleton_class.prepend(Hook)
  when "runtime"
    Kernel.prepend(Hook)
    BUNDLER_HOOK = Module.new do
      def require(*groups) = HayateSpike.track("Bundler.require") { super }
    end
    # Bundler::Runtime が定義された時点で prepend (require "bundler/runtime" の後)
    TracePoint.new(:end) { |tp| (Bundler::Runtime.prepend(BUNDLER_HOOK); tp.disable) if tp.self.name == "Bundler::Runtime" }.enable
  when "chain"
    [Kernel, Kernel.singleton_class].each do |k|
      k.class_eval do
        alias_method :__hayate_require, :require
        alias_method :require, :require # 再定義警告の抑止 (bootsnap と同じ手法)
        def require(name) = HayateSpike.track(name) { __hayate_require(name) }
      end
    end
    Kernel.send(:private, :require, :__hayate_require)
  end

  CALLS = Hash.new(0)
  TP = TracePoint.new(:call) do |tp|
    next unless tp.method_id == :require
    case tp.path
    when /bootsnap.*kernel_require/ then CALLS[:bootsnap] += 1
    when /zeitwerk.*kernel/ then CALLS[:zeitwerk] += 1
    when /bundled_gems/ then CALLS[:bundled_gems] += 1
    end
  end
  TP.enable if ENV["HAYATE_TP"]
  at_exit do
    slow = EV.select { _1[0] =~ /slowgem/ }.map { |n, _, d, t| "#{' ' * d}#{File.basename(n)}=#{(t * 1000).round}ms" }
    $stderr.puts "[#{V}] events=#{EV.size} wrappers=#{CALLS.to_h} slowgem=#{slow.join(' ')}"
  end
end
