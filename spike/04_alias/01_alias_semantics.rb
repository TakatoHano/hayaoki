# frozen_string_literal: true
# Spike 4-1: prepend 済みの Kernel / Kernel.singleton_class に対し、後から alias_method + 再定義
# (bundled_gems / Zeitwerk / bootsnap と同じ alias chain) を行ったとき何が起きるかを最小再現する。
# 使い方: ruby 01_alias_semantics.rb [instance|singleton] [super|callee]
#   super : フックは常に super で委譲 (素朴な prepend)
#   callee: __callee__ が :require 以外 (= alias で複製された) なら保存済み元メソッドへ bind_call
TARGET = ARGV[0] || "singleton"
MODE = ARGV[1] || "super"
ORIG = { Kernel => Kernel.instance_method(:require), Kernel.singleton_class => Kernel.method(:require).unbind }
module Hook
  DEPTH = [0]
  def require(name)
    raise "runaway recursion" if (DEPTH[0] += 1) > 20
    $stdout.puts "  hook(#{__callee__}) #{name}"
    if MODE == "callee" && __callee__ != :require
      k = equal?(Kernel) ? Kernel.singleton_class : Kernel
      return ORIG[k].bind_call(self, name)
    end
    super
  ensure
    DEPTH[0] -= 1
  end
end
k = TARGET == "instance" ? Kernel : Kernel.singleton_class
k.prepend(Hook)
k.send(:alias_method, :chain_orig_require, :require)
k.send(:define_method, :require) { |n| $stdout.puts "  chain"; chain_orig_require(n) }
k.send(:private, :require) if k == Kernel
puts "#{TARGET}/#{MODE}: ancestors=#{k.ancestors.first(3).inspect}"
begin
  TARGET == "instance" ? require("json") : Kernel.require("json")
  puts "  => ok"
rescue Exception => e
  puts "  => FAIL #{e.class}: #{e.message[0, 80]}"
end
