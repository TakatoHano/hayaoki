# frozen_string_literal: true
# Spike 3: probe オーバーヘッド計測用。HAYATE_PROBE_MODE=hook なら記録せずフックのみ
require "json"
module HayateProbe
  EVENTS = []
  RECORD = ENV["HAYATE_PROBE_MODE"] != "hook"
  CLOCK = Process::CLOCK_MONOTONIC
  @depth = 0
  class << self; attr_accessor :depth; end

  def require(name)
    __hayate_track(name) { super }
  end

  # require に委譲すると RubyGems の require を通って +45% になるため、
  # 本来の require_relative と同じく RubyGems を経由しない gem_original_require を使う
  def require_relative(name)
    base = caller_locations(1, 1).first.absolute_path or raise LoadError, "cannot infer basepath"
    path = File.expand_path(name, File.dirname(base))
    __hayate_track(path) { gem_original_require(path) }
  end

  private def __hayate_track(name)
    d = HayateProbe.depth
    HayateProbe.depth = d + 1
    t0 = Process.clock_gettime(CLOCK) if RECORD
    result = yield
    if RECORD
      EVENTS << { name: name, depth: d, start: t0, duration: Process.clock_gettime(CLOCK) - t0,
                  feature: result ? $LOADED_FEATURES.last : nil }
    end
    result
  ensure
    HayateProbe.depth = d
  end

  def load(name, wrap = false)
    super
  end
end
Kernel.prepend(HayateProbe)
Kernel.singleton_class.prepend(HayateProbe)
at_exit do
  File.write("/dev/null", JSON.generate(HayateProbe::EVENTS)) if HayateProbe::RECORD
  File.write(ENV["HAYATE_COUNT_FILE"], HayateProbe::EVENTS.size.to_s) if ENV["HAYATE_COUNT_FILE"]
end
