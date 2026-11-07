# frozen_string_literal: true

require "test_helper"

# Rails を使った結合テスト。rails (と bundler) が使えない環境では skip する。
class ProbeRailsTest < Minitest::Test
  include ProbeHelper

  APP_SRC = File.join(FIXTURES, "apps/rails_min")
  RAILS_ENV_VARS = { "RAILS_ENV" => "production", "DISABLE_SPRING" => "1" }.freeze

  class << self
    attr_reader :app_dir

    def rails_available?
      @rails_available ||= begin
        !Gem::Specification.find_all_by_name("rails").empty? && !Gem::Specification.find_all_by_name("zeitwerk").empty?
      end
    end

    def bootsnap_available? = !Gem::Specification.find_all_by_name("bootsnap").empty?

    # fixture アプリを tmp に複製し、ローカルの gem だけで Gemfile.lock を作る (1 回だけ)
    def prepare_app
      return @app_dir if @app_dir
      @tmp = Dir.mktmpdir("hayate-rails")
      Minitest.after_run { FileUtils.rm_rf(@tmp) }
      FileUtils.cp_r(APP_SRC, @tmp)
      dir = File.realpath(File.join(@tmp, "rails_min"))
      so, st = Open3.capture2e(CLEAN_ENV, RbConfig.ruby, "-S", "bundle", "lock", "--local", chdir: dir)
      @lock_error = st.success? ? nil : so
      @app_dir = dir
    end

    attr_reader :lock_error
  end

  def setup
    skip "rails is not installed" unless self.class.rails_available?
    @dir = self.class.prepare_app
    skip "bundle lock --local failed: #{self.class.lock_error.to_s[0, 300]}" if self.class.lock_error
  end

  def boot(env, probe:, code: 'require "./config/environment"')
    run_probe(code, chdir: @dir, env: RAILS_ENV_VARS.merge(env), probe_args: probe ? [PROBE] : [])
  end

  def check_boot(env)
    r = boot(env, probe: true)
    assert_predicate r.status, :success?, r.err
    rep = r.report
    refute_nil rep, "probe produced no output: #{r.err}"
    assert_equal "ok", rep["status"], rep["error"].inspect
    assert_empty rep["probe_errors"]
    assert_equal @dir, rep["rails_root"]
    assert_equal [], rep["pending_hooks"], "all Rails hooks installed"

    inits = rep.of_kind(ProbeReport::K_INIT)
    assert_operator inits.size, :>, 10, "initializer spans"
    assert(inits.any? { |s| s.name == "load_config_initializers" })
    assert(inits.any? { |s| s.name.include?("eager_load!") })
    assert_operator rep.of_kind(ProbeReport::K_EAGER).size, :>=, 1, "Zeitwerk eager_load span"
    assert_equal 1, rep.named(ProbeReport::K_PHASE, "initialize").size
    assert_equal 1, rep.named(ProbeReport::K_PHASE, "bundler_require").size
    assert_operator rep.of_kind(ProbeReport::K_ONLOAD).size, :>, 5, "on_load spans"
    assert_operator rep.of_kind(ProbeReport::K_HOOKS).size, :>, 5

    # path gem (Rails.root 配下) の時間
    slowgem = rep.feature("/slowgem/lib/slowgem.rb").first
    refute_nil slowgem
    assert_operator slowgem.self_ms, :>=, 99
    assert_operator slowgem.self_ms, :<, 99 + 25
    inner = rep.feature("/slowgem/inner.rb")
    assert_equal 1, inner.size
    assert_equal ProbeReport::K_RR, inner.first.kind
    assert_operator inner.first.self_ms, :>=, 49
    assert_operator rep.feature("/slowgem/other.rb").first.self_ms, :>=, 29
    owned = rep.of_kind(ProbeReport::K_ONLOAD).select { |s| s.res.to_s.include?("/slowgem/lib/slowgem.rb:") }
    assert_equal 1, owned.size
    assert_operator owned.first.dur_ms, :>=, 39

    # config/initializers/spike.rb の sleep 0.02 は load_config_initializers の中の load として現れる
    spike = rep.of_kind(ProbeReport::K_LOAD).find { |s| s.name.to_s.end_with?("config/initializers/spike.rb") }
    refute_nil spike
    assert_operator spike.dur_ms, :>=, 19
    lci = rep.named(ProbeReport::K_INIT, "load_config_initializers").find { |i| i.children.include?(spike) || rep.spans.find { |x| x.idx == spike.parent } == i }
    refute_nil lci, "spike.rb is loaded inside an initializer span"
    assert_operator lci.dur_ms, :>=, 19

    # 暗黙の名前空間 (app/models/admin/) を含むアプリが eager_load できている
    assert(rep.feature("/app/models/admin/thing.rb").any?)
    rep
  end

  def test_boot_with_bootsnap
    skip "bootsnap is not installed" unless self.class.bootsnap_available?
    boot({}, probe: false) # warm cache
    check_boot({})
  end

  def test_boot_without_bootsnap
    check_boot("NO_BOOTSNAP" => "1")
  end

  def test_probe_does_not_change_the_boot_result
    code = 'require "./config/environment"; puts Rails.application.initialized?; puts $LOADED_FEATURES.reject { |f| f.end_with?("/hayate/probe.rb") }.sort'
    [{}, { "NO_BOOTSNAP" => "1" }].each do |env|
      next if env.empty? && !self.class.bootsnap_available?
      boot(env, probe: false, code: code) # warm-up (bootsnap cache)
      plain = boot(env, probe: false, code: code)
      with = boot(env, probe: true, code: code)
      assert_predicate plain.status, :success?, plain.err
      assert_equal "true", plain.out.lines.first.strip
      assert_equal plain.out, with.out, "initialized? and $LOADED_FEATURES are identical (#{env})"
      assert_equal plain.err, with.err, "warnings (e.g. bundled_gems) are identical (#{env})"
    end
  end

  def test_boot_end_is_the_close_of_environment_rb
    rep = boot({ "NO_BOOTSNAP" => "1" }, probe: true).report
    root = rep.feature("/config/environment.rb").first
    refute_nil root
    assert_equal root.t1, rep["boot_end_us"]
    assert_operator rep["false_require"]["count"], :>, 0
  end
end
