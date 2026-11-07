# frozen_string_literal: true
# Spike 1: require 直後の $LOADED_FEATURES.last で「今 require したファイル」を特定できるか
#   + どの読み込み方法が Kernel#require の prepend で捕捉できるか
require "tmpdir"
require "fileutils"

dir = Dir.mktmpdir("hayate-spike")
File.write("#{dir}/a.rb", "require 'b'\nrequire_relative 'rel'\nA = 1\n")
File.write("#{dir}/b.rb", "require 'c'\nB = 1\n")
File.write("#{dir}/c.rb", "C = 1\n")
File.write("#{dir}/rel.rb", "require 'c'\nREL = 1\n")           # c は既に読み込み済み → false
File.write("#{dir}/circ1.rb", "require 'circ2'\nCIRC1 = 1\n")
File.write("#{dir}/circ2.rb", "require 'circ1'\nCIRC2 = 1\n")   # 循環 require (警告は出るが false)
File.write("#{dir}/auto.rb", "module Auto; end\n")
File.write("#{dir}/raises.rb", "require 'c2'\nraise 'boom'\n")
File.write("#{dir}/c2.rb", "C2 = 1\n")
File.write("#{dir}/loaded.rb", "LOADED = 1\n")
$LOAD_PATH.unshift(dir)

EVENTS = []
module Probe
  def require(name)
    depth = (Thread.current[:d] ||= 0)
    Thread.current[:d] = depth + 1
    before = $LOADED_FEATURES.size
    result = super
    added = $LOADED_FEATURES[before..] || []
    EVENTS << [:require, depth, name, result, result ? File.basename($LOADED_FEATURES.last) : nil, added.map { File.basename(_1) }]
    result
  rescue Exception => e
    EVENTS << [:require_raise, depth, name, e.class]
    raise
  ensure
    Thread.current[:d] = depth
  end

  # super だと基準パスが probe 自身になるため、呼び出し元から絶対パスを解決して require に委譲
  def require_relative(name)
    EVENTS << [:require_relative, Thread.current[:d], name]
    base = caller_locations(1, 1).first.absolute_path or raise LoadError, "cannot infer basepath"
    require(File.expand_path(name, File.dirname(base)))
  end

  def load(name, wrap = false)
    EVENTS << [:load, Thread.current[:d], name]
    super
  end
end
Kernel.prepend(Probe)
Kernel.singleton_class.prepend(Probe)

require "a"
autoload :Auto, "auto"
Auto
Kernel.require "c2"      # Kernel.require (module function) 経由
begin; require "raises"; rescue RuntimeError; end
require "circ1"
load "#{dir}/loaded.rb"
require "json"           # 拡張ライブラリ (.bundle/.so) を含む gem

ok = true
EVENTS.each do |ev|
  if ev[0] == :require && ev[3]
    match = ev[4].sub(/\.(rb|so|bundle)\z/, "") == File.basename(ev[2]).sub(/\.(rb|so|bundle)\z/, "")
    ok &&= match
    puts format("%-16s d=%d %-24s -> last=%-22s %s added=%p", ev[0], ev[1], ev[2], ev[4], match ? "OK " : "NG!", ev[5])
  else
    puts format("%-16s d=%p %-24s %p", ev[0], ev[1], ev[2], ev[3..])
  end
end
puts(ok ? "RESULT: $LOADED_FEATURES.last は常に自分自身" : "RESULT: 不一致あり")
FileUtils.rm_rf(dir)
