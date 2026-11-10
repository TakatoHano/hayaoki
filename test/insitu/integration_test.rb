# frozen_string_literal: true

require_relative "../test_helper"

# Boots the fixture Rails app (rails_min + the insitu_overlay files) in a child process with
# `require "hayaoki/insitu"` in config/boot.rb and checks the emitted line.
class InsituIntegrationTest < Minitest::Test
  OVERLAY = File.join(FIXTURES, "apps/insitu_overlay")

  class << self
    attr_reader :lock_error

    def rails_available?
      %w[rails zeitwerk].all? { !Gem::Specification.find_all_by_name(_1).empty? }
    end

    def app_dir
      return @app_dir if @app_dir
      @app_dir, @lock_error = prepare_rails_min_app("hayaoki-insitu")
      FileUtils.cp_r("#{OVERLAY}/.", @app_dir)
      @app_dir
    end
  end

  def run_app(paths, env = {}, script = "drive.rb")
    skip "rails is not installed" unless self.class.rails_available?
    dir = self.class.app_dir
    skip "bundle lock --local failed: #{self.class.lock_error.to_s[0, 300]}" if self.class.lock_error
    out = File.join(dir, "tmp", "insitu-#{name}.log")
    FileUtils.mkdir_p(File.dirname(out))
    FileUtils.rm_f(out)
    e = CLEAN_ENV.merge("HAYAOKI_INSITU" => "1", "RAILS_ENV" => "production", "HAYAOKI_INSITU_OUT" => out,
                        "DRIVE_PATHS" => paths.join(","), "K_SERVICE" => nil, "AWS_LAMBDA_FUNCTION_NAME" => nil).merge(env)
    so, se, st = Open3.capture3(e, RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", script, chdir: dir)
    assert st.success?, "child failed: #{so}\n#{se}"
    refute_match(/hayaoki insitu/, se)
    File.exist?(out) ? File.readlines(out) : []
  end

  def test_first_request_line
    lines = run_app(["/up", "/?token=secret", "/"])
    assert_equal 1, lines.size, lines.join
    raw = lines[0]
    refute_includes raw, "secret"
    assert_operator raw.bytesize, :<=, 4096
    l = JSON.parse(raw)

    assert_equal %w[hayaoki v severity message status id pid worker start_at start_source ready_source platform
                    runtime marks_ms phases_ms phases_cpu_ms eager_top first_request proc limits], l.keys
    assert_equal ["cold_start", 1, "INFO", "ok"], l.values_at("hayaoki", "v", "severity", "status")
    assert_match(/\A\h{8}\z/, l["id"])
    assert_equal false, l["worker"]
    assert_equal "probe", l["ready_source"]
    assert_includes %w[proc_stat load], l["start_source"]
    assert_equal({"kind" => "generic"}, l["platform"])

    rt = l["runtime"]
    assert_equal "production", rt["env"]
    assert_equal "boot_rb", rt["entry"]
    assert_equal true, rt["eager_load"]
    assert_match(/\A\d+\.\d+/, rt["rails"])

    m = l["marks_ms"]
    order = %w[loaded bundler_require_start bundler_require_end initialize_start initialize_end first_probe first_request_start first_response_end]
    order.each { assert_kind_of Integer, m[_1], _1 }
    order.each_cons(2) { |a, b| assert_operator m[a], :<=, m[b], "#{a} <= #{b}" }

    pc = l["phases_cpu_ms"]
    %w[bundler_require initialize load_to_ready load_to_first_response].each { assert_kind_of Numeric, pc[_1], _1 }
    assert_kind_of Integer, l["proc"]["cpu_at_load_ms"]
    # Linux kernels without CONFIG_SCHED_INFO have no schedstat; both keys are present either way
    assert l["proc"].key?("main_thread_runq_wait_ms")
    assert l["proc"].key?("main_thread_runq_wait_at_load_ms")
    assert_equal %w[cgroup cpu_quota nproc mem_max_mb sandbox], l["limits"].keys
    assert_operator l["limits"]["nproc"], :>=, 1

    ph = l["phases_ms"]
    assert_operator ph["bundler_require"], :>=, 150 # slowgem sleeps 0.18 s
    assert_operator ph["eager_load"], :<=, ph["initialize"]
    assert_equal m["first_probe"], ph["to_ready"]
    assert_equal m["first_response_end"], ph["to_first_response"]
    refute_empty l["eager_top"]

    fr = l["first_request"]
    assert_equal "home#index", fr["route"]
    assert_equal 200, fr["status"]
    assert_equal 1, fr["probe_hits"]
    assert_kind_of Integer, fr["new_features"]
    fr["new_by_group"].each { |g, n| assert_match(/\A<(gem:[\w.-]+|app|stdlib|other)>\z/, g) && assert_kind_of(Integer, n) }

    pr = l["proc"]
    %w[cpu_ms gc_count gc_time_ms features].each { assert_kind_of Integer, pr[_1], _1 }
    assert_includes [true, false], pr["i18n_loaded"]
  end

  def test_no_request_emits_at_exit
    lines = run_app([])
    assert_equal 1, lines.size
    l = JSON.parse(lines[0])
    assert_equal "no_request", l["status"]
    assert_equal "initialize", l["ready_source"]
    assert_nil l["first_request"]
    assert_equal l["marks_ms"]["initialize_end"], l["phases_ms"]["to_ready"]
  end

  def test_emit_ready_mode
    lines = run_app(["/"], "HAYAOKI_INSITU_EMIT" => "ready")
    assert_equal 1, lines.size
    l = JSON.parse(lines[0])
    assert_equal "ok", l["status"]
    assert_equal "initialize", l["ready_source"]
    assert_nil l["first_request"]
    assert_nil l["marks_ms"]["first_request_start"]
    assert_match(/\Ahayaoki cold start: ready \d+ms\z/, l["message"])
  end

  # `bin/rails db:prepare` (run by the default docker-entrypoint before the server) must not
  # write a no_request line, nor an ok line in ready mode.
  def test_rails_rake_task_writes_nothing
    assert_empty run_app([], {}, "rails_task.rb")
    assert_empty run_app([], {"HAYAOKI_INSITU_EMIT" => "ready"}, "rails_task.rb")
  end

  def test_off_writes_nothing
    assert_empty run_app(["/"], "HAYAOKI_INSITU" => "0")
  end
end
