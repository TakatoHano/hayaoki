# frozen_string_literal: true
# Spike 2: bootsnap + Zeitwerk 入りの Rails で Probe が計測を欠かさず共存できるか
# 使い方: ruby -r./02_probe.rb -e 'require "./config/environment"'  (または boot 後に require)
unless defined?(HayaokiProbe)
  module HayaokiProbe
    SING_REQUIRE = Kernel.method(:require).unbind
    PRE = $LOADED_FEATURES.dup  # probe 読込時点で既にロード済みの feature
    EVENTS = []   # [name, result, last_or_nil, depth]
    RELATIVE = [] # require_relative 呼び出し記録
    LOADS = []
    RR_VIA_REQUIRE = ENV["PROBE_RR"] == "require"
    CAPTURED = {} # 絶対パス => true (require が true を返した時の $LOADED_FEATURES.last)

    module Hook
      def require(name)
        depth = (Thread.current[:hayaoki_d] ||= 0)
        Thread.current[:hayaoki_d] = depth + 1
        result = __hayaoki_next_require(name) { super }
        last = result ? $LOADED_FEATURES.last : nil
        EVENTS << [name.to_s, result, last, depth]
        CAPTURED[last] = true if last
        result
      rescue Exception => e
        EVENTS << [name.to_s, :raise, nil, depth]
        raise
      ensure
        Thread.current[:hayaoki_d] = depth
      end

      # Kernel.require (singleton) だけは super を使わず、prepend 前の元メソッドを直接呼ぶ。
      # 理由: Ruby 4.0 の bundled_gems.rb (replace_require) が singleton の require を
      # alias_method で退避するとき、先頭の Hook#require を退避してしまい、
      # 退避版内の super が "no superclass method 'require' for class #<Class:Kernel>" で落ちるため。
      private def __hayaoki_next_require(name)
        if equal?(Kernel)
          HayaokiProbe::SING_REQUIRE.bind_call(Kernel, name)
        else
          yield
        end
      end

      # super だと基準パスが正しく解決されないため、呼び出し元から絶対パスを解決して委譲する。
      # 既定は gem_original_require (RubyGems の require を経由せず本来の require_relative と同等)。
      # PROBE_RR=require で require 委譲版 (RubyGems 経由) に切替可能。
      def require_relative(name)
        RELATIVE << name
        base = caller_locations(1, 1).first.absolute_path or raise LoadError, "cannot infer basepath"
        path = File.expand_path(name, File.dirname(base))
        return require(path) if HayaokiProbe::RR_VIA_REQUIRE
        depth = (Thread.current[:hayaoki_d] ||= 0)
        Thread.current[:hayaoki_d] = depth + 1
        result = gem_original_require(path)
        last = result ? $LOADED_FEATURES.last : nil
        EVENTS << [path, result, last, depth, :rr]
        CAPTURED[last] = true if last
        result
      rescue Exception
        EVENTS << [path || name.to_s, :raise, nil, depth, :rr]
        raise
      ensure
        Thread.current[:hayaoki_d] = depth if depth
      end

      def load(name, wrap = false)
        LOADS << name.to_s
        super
      end
    end

    def self.strip(p) = p.to_s.sub(/\.(rb|so|bundle)\z/, "")

    def self.report
      real = ->(p) { File.realpath(p) rescue p }
      ok = EVENTS.select { _1[1] == true }
      match = ok.count { _1[2] && strip(File.basename(_1[2])) == strip(File.basename(_1[0])) ||
                         (_1[2] && strip(_1[2]).end_with?(strip(_1[0]))) }
      feats = $LOADED_FEATURES
      cap = CAPTURED.keys.map(&real).to_h { [_1, true] }
      covered = feats.count { cap[real.(_1)] }
      app_dir = real.(ENV["PROBE_APP_DIR"] || File.join(Dir.pwd, "app"))
      app_files = Dir[File.join(app_dir, "**/*.rb")].map(&real)
      app_cap = app_files.count { cap[_1] }
      missing = feats.reject { cap[real.(_1)] }
      pre = PRE.to_h { [real.(_1), true] }
      post_missing = missing.reject { pre[real.(_1)] }
      dup = EVENTS.group_by { _1[2] }.select { |k, v| k && v.size > 1 }.size
      err = $stderr
      err.puts "[probe] label=#{ENV['PROBE_LABEL']}"
      err.puts "[probe] require events=#{EVENTS.size} (true=#{ok.size}, false=#{EVENTS.count { _1[1] == false }}, raise=#{EVENTS.count { _1[1] == :raise }}) require_relative=#{RELATIVE.size} load=#{LOADS.size}"
      err.puts "[probe] last-match=#{match}/#{ok.size} (#{ok.empty? ? 'n/a' : (100.0 * match / ok.size).round(1)}%)"
      err.puts "[probe] LOADED_FEATURES=#{feats.size} captured=#{covered} coverage=#{(100.0 * covered / feats.size).round(1)}%  duplicate-last=#{dup}"
      err.puts "[probe] pre-probe features=#{PRE.size} / post-probe features=#{feats.size - PRE.size} uncaptured-post-probe=#{post_missing.size} #{post_missing.first(5).map { File.basename(_1) }.inspect}"
      err.puts "[probe] app files captured=#{app_cap}/#{app_files.size}"
      err.puts "[probe] Kernel#require owner=#{Kernel.instance_method(:require).owner}  ancestors=#{Kernel.ancestors.first(5).inspect}"
      err.puts "[probe] missing(sample)=#{missing.first(5).map { File.basename(_1) }.inspect}" unless missing.empty?
      File.write(ENV["PROBE_MISSING_OUT"], missing.join("\n")) if ENV["PROBE_MISSING_OUT"]
    end
  end
  Kernel.prepend(HayaokiProbe::Hook)
  Kernel.singleton_class.prepend(HayaokiProbe::Hook)
  at_exit { HayaokiProbe.report }
end
