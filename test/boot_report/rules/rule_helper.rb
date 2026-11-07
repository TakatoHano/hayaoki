# frozen_string_literal: true

require "test_helper"
require "hayate"
require "hayate/boot_report/report"
require "hayate/boot_report/advisor"
require "hayate/boot_report/rules/dev_gems_in_production"
require "hayate/boot_report/rules/bootsnap_ineffective"
require "hayate/boot_report/rules/heavy_app_initializer"
require "hayate/boot_report/rules/unused_heavy_gem"
require "hayate/boot_report/rules/eager_load_tradeoff"

module RuleHelper
  B = Hayate::BootReport

  def st(m) = { "median" => m, "min" => m, "max" => m }

  def gem_row(name, ms, category: "gem", **extra)
    { "name" => name, "category" => category, "self_ms" => st(ms), "require_ms" => st(ms),
      "on_load_ms" => st(0), "initializer_count" => st(0) }.merge(extra)
  end

  # 文字列キーの Report。overrides で各属性を差し替える。
  def make_report(**o)
    B::Report.new(**{
      condition: "warm", runs: 3, failed: 0,
      phases: { "boot" => st(1000.0), "total" => st(1040.0), "eager_load" => nil },
      categories: {}, gems: [], files: [], initializers: [], on_loads: [], false_require: nil, threads: {},
      ruby: "x", features: nil, meta: { "env" => "production" }, warnings: []
    }.merge(o))
  end

  def run_rule(klass, report, app_dir: @app_dir, result: nil, **th)
    ctx = B::Context.new(report: report, app_dir: app_dir, result: result,
                         initializer_threshold_ms: th[:init] || 50, gem_threshold_ms: th[:gem] || 30)
    klass.new(ctx).call
  end

  def with_app(files = {})
    Dir.mktmpdir("hayate-app") do |dir|
      files.each do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      @app_dir = dir
      yield dir
    end
  end
end
