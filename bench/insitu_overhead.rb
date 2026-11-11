# frozen_string_literal: true

# in-situ logging の全体オーバーヘッドを A/B で測る。設計は docs/design/phase2.md §2.3。
# 使い方: ruby bench/insitu_overhead.rb [--runs N] [--requests N] [--json]
#   A: HAYAOKI_INSITU=0 (計測しない) / B: HAYAOKI_INSITU=1 (出力先は tmp ファイル)
#   起動: fixture アプリ (rails_min + insitu_overlay) を新しいプロセスで boot し、最初のリクエストを送り終えるまでの壁時計時間
#   リクエスト: 子プロセス内で boot 後に N 回 Rack::MockRequest を通した 1 回あたりの平均 (ns)
# A と B は交互に実行し、中央値と p90 を出す。
require "json"
require "optparse"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
FIXTURES = File.join(ROOT, "test/fixtures/apps")
OVERLAY = File.join(FIXTURES, "insitu_overlay")
REQ_BUDGET_NS = 100 # docs/design/phase2.md §2.3: 最初の後のリクエストは 1 回の ivar 確認 (< 100 ns)

# test/test_helper.rb の CLEAN_ENV と同じ: bundle exec 由来の環境を子に持ち込まない
CLEAN_ENV = {
  "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
  "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "HAYAOKI_PROBE_OUT" => nil, "HAYAOKI_SPAWN_AT" => nil,
  "HAYAOKI_INSITU_OUT" => nil, "HAYAOKI_INSITU_SAMPLER" => nil, "K_SERVICE" => nil, "AWS_LAMBDA_FUNCTION_NAME" => nil,
}.freeze

# 子プロセス (リクエスト計測): boot 後に最初の 1 回を送り、続けて N 回の平均 ns を出す
if (n = ENV["HAYAOKI_INSITU_BENCH_N"])
  require "./config/environment"
  require "rack/mock"
  app = Rack::MockRequest.new(Rails.application)
  app.get("/") # 最初のリクエスト (B はここで emit する)
  n = Integer(n)
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n.times { app.get("/") }
  puts((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1e9 / n)
  exit
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0

def tail(str) = str.to_s.lines.last(15).join

# fixture を tmp に複製し、ローカルの gem だけで lock を作り直す (test_helper の prepare_rails_min_app と同じ)
def prepare_app
  tmp = Dir.mktmpdir("hayaoki-insitu-bench")
  at_exit { FileUtils.rm_rf(tmp) }
  FileUtils.cp_r(File.join(FIXTURES, "rails_min"), tmp)
  dir = File.realpath(File.join(tmp, "rails_min"))
  FileUtils.cp_r("#{OVERLAY}/.", dir)
  FileUtils.rm_f(File.join(dir, "Gemfile.lock"))
  so, st = Open3.capture2e(CLEAN_ENV.merge("BUNDLE_LOCKFILE_CHECKSUMS" => "false"),
                           RbConfig.ruby, "-S", "bundle", "lock", "--local", chdir: dir)
  raise "bundle lock --local failed:\n#{tail(so)}" unless st.success?
  dir
end

def env_for(variant, out)
  e = CLEAN_ENV.merge("RAILS_ENV" => "production", "HAYAOKI_INSITU" => variant == :b ? "1" : "0")
  e["HAYAOKI_INSITU_OUT"] = out if variant == :b
  e["HAYAOKI_INSITU_SAMPLER"] = "1" if variant == :b && $sampler
  e
end

# 起動 + 最初のリクエストの壁時計時間 (ms)
def boot_sample(dir, variant)
  Dir.mktmpdir("hayaoki-insitu-out") do |od|
    out = File.join(od, "line.json")
    t = now
    _so, se, st = Open3.capture3(env_for(variant, out).merge("DRIVE_PATHS" => "/"),
                                 RbConfig.ruby, "-I#{ROOT}/lib", "drive.rb", chdir: dir)
    ms = now - t
    raise "#{variant} boot failed:\n#{tail(se)}" unless st.success?
    if variant == :b
      lines = File.exist?(out) ? File.readlines(out).size : 0
      raise "B wrote #{lines} lines (want 1)" unless lines == 1
    end
    ms
  end
end

# 1 プロセス内で N 回のリクエストを通した 1 回あたりの平均 (ns)
def req_sample(dir, variant, n)
  Dir.mktmpdir("hayaoki-insitu-req") do |od|
    e = env_for(variant, File.join(od, "line.json")).merge("HAYAOKI_INSITU_BENCH_N" => n.to_s)
    so, se, st = Open3.capture3(e, RbConfig.ruby, "-I#{ROOT}/lib", File.expand_path(__FILE__), chdir: dir)
    raise "#{variant} requests failed:\n#{tail(se)}" unless st.success?
    Float(so.lines.last)
  end
end

def pct(values, q) = values.sort[((values.size - 1) * q).round]

opts = { runs: 15, requests: 10_000, json: false }
OptionParser.new do |o|
  o.banner = "usage: ruby bench/insitu_overhead.rb [--runs N] [--requests N] [--json]"
  o.on("--runs N", Integer, "A/B pairs (default 15)") { opts[:runs] = _1 }
  o.on("--requests N", Integer, "requests per child for the per-request measurement (default 10000)") { opts[:requests] = _1 }
  o.on("--json", "print JSON instead of the table") { opts[:json] = true }
  o.on("--sampler", "B also sets HAYAOKI_INSITU_SAMPLER=1 (Linux)") { $sampler = true }
end.parse!

dir = prepare_app
boot_sample(dir, :a) # 1 回目は bootsnap キャッシュの作成などのウォームアップ
boot_sample(dir, :b)

boot = { a: [], b: [] }
req = { a: [], b: [] }
opts[:runs].times do |i|
  order = i.even? ? %i[a b] : %i[b a] # 実行順の偏りを相殺する
  order.each { boot[_1] << boot_sample(dir, _1) }
end
opts[:runs].times do |i|
  order = i.even? ? %i[a b] : %i[b a]
  order.each { req[_1] << req_sample(dir, _1, opts[:requests]) }
end

stat = lambda do |v|
  { "median" => pct(v, 0.5).round(2), "p90" => pct(v, 0.9).round(2) }
end
boot_a, boot_b = stat.(boot[:a]), stat.(boot[:b])
req_a, req_b = stat.(req[:a]), stat.(req[:b])
delta_req = (req_b["median"] - req_a["median"]).round(1)

# 予算の判定は middleware 単体で測る。アプリ全体を通した差はノイズ (~0.3%) に埋もれる
require_relative "../lib/hayaoki/insitu/middleware"
micro = lambda do
  app = ->(_env) { [200, {}, []] }
  state = Struct.new(:fork_gen, :ignore_paths, :emit_at).new(0, ["/up"], "first_response")
  mw = Hayaoki::Insitu::Middleware.new(app, state)
  mw.instance_variable_set(:@done_gen, 0) # 最初のリクエストの後の素通し状態
  env = { "PATH_INFO" => "/" }
  n = 1_000_000
  Array.new(5) do
    t = now; n.times { app.call(env) }; direct = now - t
    t = now; n.times { mw.call(env) }; via = now - t
    (via - direct) / n * 1e6 # ms → ns
  end.sort[2].round(1)
end
delta_mw = micro.()

result = {
  "runs" => opts[:runs],
  "requests" => opts[:requests],
  "boot_first_request_ms" => {
    "a" => boot_a, "b" => boot_b,
    "delta" => { "median" => (boot_b["median"] - boot_a["median"]).round(2), "p90" => (boot_b["p90"] - boot_a["p90"]).round(2) },
  },
  "per_request_ns" => {
    "a" => req_a, "b" => req_b,
    "delta_median" => delta_req,
    "middleware_passthrough_delta" => delta_mw,
    "budget" => REQ_BUDGET_NS,
    "within_budget" => delta_mw < REQ_BUDGET_NS,
  },
}

if opts[:json]
  puts JSON.pretty_generate(result)
else
  puts format("%-28s %10s %10s %10s", "metric", "A (off)", "B (on)", "delta")
  puts format("%-28s %10.2f %10.2f %10.2f", "boot+first req median ms", boot_a["median"], boot_b["median"],
              boot_b["median"] - boot_a["median"])
  puts format("%-28s %10.2f %10.2f %10.2f", "boot+first req p90 ms", boot_a["p90"], boot_b["p90"],
              boot_b["p90"] - boot_a["p90"])
  puts format("%-28s %10.1f %10.1f %10.1f", "per-request median ns", req_a["median"], req_b["median"], delta_req)
  puts format("%-28s %10.1f %10.1f %10s", "per-request p90 ns", req_a["p90"], req_b["p90"],
              format("%.1f", req_b["p90"] - req_a["p90"]))
  puts format("%-28s %10s %10s %10.1f", "middleware pass-through ns", "", "", delta_mw)
  puts "per-request budget (middleware pass-through): < #{REQ_BUDGET_NS} ns delta => #{result["per_request_ns"]["within_budget"] ? "ok" : "OVER"}"
end
