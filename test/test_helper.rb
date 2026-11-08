# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
PROBE = File.join(ROOT, "lib/hayaoki/probe.rb")
FIXTURES = File.join(__dir__, "fixtures")
# CI ランナー (特に macOS) は時間のばらつきが大きいので、上限側の許容幅を広げる
TIMING_SLACK = ENV["CI"] ? (RUBY_PLATFORM.include?("darwin") ? 4 : 2) : 1

# 子プロセスに bundle exec 由来の環境を持ち込まない (probe を -r で先頭に読ませるため)
CLEAN_ENV = {
  "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
  "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "HAYAOKI_PROBE_OUT" => nil, "HAYAOKI_SPAWN_AT" => nil,
}.freeze

# probe の出力 JSON を木として扱うテスト用の補助 (親側の集計の実装ではない)
class ProbeReport
  Span = Struct.new(:idx, :kind, :name, :parent, :t0, :t1, :res, :tid, :cpu, :children) do
    def dur_ms = t1 && (t1 - t0) / 1000.0
    def self_ms = dur_ms - children.sum { |c| c.t1 ? c.dur_ms : 0 }
    def raised? = res == "raised"
    def feature = res.is_a?(String) && !raised? ? res : nil
  end

  K_REQ = 0; K_RR = 1; K_LOAD = 2; K_INIT = 3; K_ONLOAD = 4; K_HOOKS = 5; K_EAGER = 6; K_PHASE = 7

  attr_reader :data, :spans

  def initialize(data)
    @data = data
    w = data["width"]
    @spans = data["events"].each_slice(w).each_with_index.map do |(k, n, par, s, e, res, tid, cpu), i|
      Span.new(i * w, k, n, par, s, e, res, tid, cpu, [])
    end
    by_idx = @spans.to_h { |s| [s.idx, s] }
    @spans.each { |s| by_idx[s.parent]&.children&.push(s) }
  end

  def [](key) = @data[key]

  def of_kind(kind) = @spans.select { |s| s.kind == kind }

  # require 系 (kind 0〜2) の span のうち、feature が suffix で終わるもの
  def feature(suffix) = @spans.select { |s| s.kind <= K_LOAD && s.feature&.end_with?(suffix) }

  def named(kind, name) = @spans.select { |s| s.kind == kind && s.name == name }
end

module ProbeHelper
  Result = Struct.new(:data, :out, :err, :status) do
    def report = data && ProbeReport.new(data)
  end

  # ruby [ruby_args] -r probe -e code を実行する。HAYAOKI_PROBE_OUT の中身は data に JSON として入る。
  def run_probe(code, ruby_args: [], env: {}, chdir: File.join(FIXTURES, "edge"), probe_args: [PROBE])
    Dir.mktmpdir("hayaoki-probe") do |dir|
      out = File.join(dir, "out.json")
      cmd = [RbConfig.ruby, *ruby_args, *probe_args.map { |p| "-r#{p}" }, "-e", code]
      so, se, st = Open3.capture3(CLEAN_ENV.merge("HAYAOKI_PROBE_OUT" => out).merge(env), *cmd, chdir: chdir)
      data = File.exist?(out) ? JSON.parse(File.read(out)) : nil
      tmp_left = File.exist?("#{out}.tmp")
      refute tmp_left, "tmp file must be renamed away"
      Result.new(data, so, se, st)
    end
  end
end

# fixture の Rails アプリを tmp に複製し、古い Gemfile.lock を消してから、ローカルの gem だけで lock を作り直す。
# [app_dir, lock_error(失敗時の出力。成功なら nil)] を返す。tmp は終了時に消す。
def prepare_rails_min_app(prefix = "hayaoki-app")
  tmp = Dir.mktmpdir(prefix)
  Minitest.after_run { FileUtils.rm_rf(tmp) }
  FileUtils.cp_r(File.join(FIXTURES, "apps/rails_min"), tmp)
  dir = File.realpath(File.join(tmp, "rails_min"))
  FileUtils.rm_f(File.join(dir, "Gemfile.lock"))
  # --local では gem の checksum を取れず、Bundler 4 は空の CHECKSUMS を frozen で拒否するので、checksums なしで作る
  so, st = Open3.capture2e(CLEAN_ENV.merge("BUNDLE_LOCKFILE_CHECKSUMS" => "false"), RbConfig.ruby, "-S", "bundle", "lock", "--local", chdir: dir)
  [dir, st.success? ? nil : so]
end
