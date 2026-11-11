# frozen_string_literal: true

# Where the in-situ boot overhead goes (issue #22): A/B like bench/insitu_overhead.rb, but the child
# records CLOCK_MONOTONIC marks at each step, so the A/B delta can be split per step.
# Usage: ruby bench/insitu_breakdown.rb [--runs N]
#   spawn       parent spawn -> first line of the child (Ruby startup)
#   bundler     require "bundler/setup"
#   insitu      require "hayaoki/insitu" (B only does work; A returns early)
#   bootsnap    require "bootsnap/setup"
#   environment require "./config/environment" (Bundler.require + Rails initialize)
#   request     the first request (B emits after it)
#   exit_hooks  end of the request -> the last at_exit hook (B's at_exit)
#   teardown    last at_exit hook -> the parent sees the child exit
require "json"
require "optparse"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
FIXTURES = File.join(ROOT, "test/fixtures/apps")
STEPS = %w[spawn bundler insitu bootsnap environment request exit_hooks teardown].freeze

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0

CHILD = <<~'RUBY'
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  m = { "start" => now }
  # registered first, so it runs after every other at_exit hook
  at_exit { m["exit_hooks"] = now; File.write(ENV["MARKS_OUT"], JSON.generate(m)) }
  require "json"
  ENV["BUNDLE_GEMFILE"] ||= File.expand_path("Gemfile")
  require "bundler/setup"; m["bundler"] = now
  require "hayaoki/insitu"; m["insitu"] = now
  require "bootsnap/setup"; m["bootsnap"] = now
  require "./config/environment"; m["environment"] = now
  require "rack/mock"
  Rack::MockRequest.new(Rails.application).get("/"); m["request"] = now
RUBY

CLEAN_ENV = {
  "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
  "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "HAYAOKI_PROBE_OUT" => nil, "HAYAOKI_SPAWN_AT" => nil,
  "HAYAOKI_INSITU_OUT" => nil, "HAYAOKI_INSITU_SAMPLER" => nil, "K_SERVICE" => nil, "AWS_LAMBDA_FUNCTION_NAME" => nil,
}.freeze

def prepare_app
  tmp = Dir.mktmpdir("hayaoki-insitu-breakdown")
  at_exit { FileUtils.rm_rf(tmp) }
  FileUtils.cp_r(File.join(FIXTURES, "rails_min"), tmp)
  dir = File.realpath(File.join(tmp, "rails_min"))
  FileUtils.cp_r("#{File.join(FIXTURES, "insitu_overlay")}/.", dir)
  FileUtils.rm_f(File.join(dir, "Gemfile.lock"))
  so, st = Open3.capture2e(CLEAN_ENV.merge("BUNDLE_LOCKFILE_CHECKSUMS" => "false"),
                           RbConfig.ruby, "-S", "bundle", "lock", "--local", chdir: dir)
  raise "bundle lock --local failed:\n#{so}" unless st.success?
  File.write(File.join(dir, "breakdown.rb"), CHILD)
  dir
end

def sample(dir, variant)
  Dir.mktmpdir("hayaoki-breakdown-out") do |od|
    marks = File.join(od, "marks.json")
    e = CLEAN_ENV.merge("RAILS_ENV" => "production", "HAYAOKI_INSITU" => variant == :b ? "1" : "0", "MARKS_OUT" => marks,
                        "BOOTSNAP_CACHE_DIR" => File.join(dir, "tmp/cache"))
    e["HAYAOKI_INSITU_OUT"] = File.join(od, "line.json") if variant == :b
    t0 = now
    _so, se, st = Open3.capture3(e, RbConfig.ruby, "-I#{ROOT}/lib", "breakdown.rb", chdir: dir)
    t1 = now
    raise "#{variant} failed:\n#{se}" unless st.success?
    m = JSON.parse(File.read(marks))
    pts = [t0, m["start"], m["bundler"], m["insitu"], m["bootsnap"], m["environment"], m["request"], m["exit_hooks"], t1]
    STEPS.each_with_index.to_h { |s, i| [s, pts[i + 1] - pts[i]] }.merge("total" => t1 - t0)
  end
end

def median(v) = v.sort[(v.size - 1) / 2]

runs = 15
OptionParser.new { |o| o.on("--runs N", Integer) { runs = _1 } }.parse!
dir = prepare_app
res = { a: [], b: [] }
2.times { sample(dir, :a); sample(dir, :b) } # warm the page cache
runs.times { |i| (i.even? ? %i[a b] : %i[b a]).each { res[_1] << sample(dir, _1) } }

puts format("%-12s %9s %9s %8s", "step (ms)", "A median", "B median", "delta")
(STEPS + ["total"]).each do |s|
  a = median(res[:a].map { _1[s] })
  b = median(res[:b].map { _1[s] })
  puts format("%-12s %9.2f %9.2f %8.2f", s, a, b, b - a)
end
