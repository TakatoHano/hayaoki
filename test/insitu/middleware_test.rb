# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/middleware"
begin
  require "rack/body_proxy"
rescue LoadError
  nil
end

class InsituMiddlewareTest < Minitest::Test
  I = Hayaoki::Insitu

  def setup
    skip "rack is not installed" unless defined?(::Rack::BodyProxy)
    @dir = Dir.mktmpdir("hayaoki-mw")
    @out = File.join(@dir, "log")
    @state = I::State.new(env: {"HAYAOKI_INSITU_OUT" => @out}, load_ms: I::Clock.now_ms)
    @calls = 0
    @app = lambda do |env|
      @calls += 1
      raise "boom" if env["PATH_INFO"] == "/raise"
      env["action_dispatch.request.path_parameters"] = {controller: "issues", action: "index"}
      [200, {"content-type" => "text/plain"}, ["ok"]]
    end
    @mw = I::Middleware.new(@app, @state)
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def get(path, mw = @mw)
    status, headers, body = mw.call("PATH_INFO" => path, "QUERY_STRING" => "token=secret")
    body.each { nil }
    body.close if body.respond_to?(:close)
    [status, headers]
  end

  def lines = File.exist?(@out) ? File.readlines(@out).map { JSON.parse(_1) } : []

  def test_probe_then_first_request_then_pass_through
    get("/up")
    get("/up")
    assert_empty lines
    get("/first")
    assert_equal 1, lines.size
    l = lines[0]
    fr = l["first_request"]
    assert_equal "issues#index", fr["route"]
    assert_equal 200, fr["status"]
    assert_equal 2, fr["probe_hits"]
    assert_operator fr["new_features"], :>=, 0
    assert_kind_of Array, fr["new_by_group"]
    assert_equal "probe", l["ready_source"]
    refute_includes File.read(@out), "secret"
    refute_includes File.read(@out), "/first"
    m = l["marks_ms"]
    assert_operator m["first_probe"], :<=, m["first_request_start"]
    assert_operator m["first_request_start"], :<=, m["first_response_end"]

    get("/x")
    get("/up")
    assert_equal 1, lines.size
    assert_equal 5, @calls
  end

  def test_emits_on_body_close_not_before
    status, _, body = @mw.call("PATH_INFO" => "/")
    assert_equal 200, status
    assert_empty lines
    body.close
    assert_equal 1, lines.size
    assert_equal "body_close", lines[0]["first_request"]["end_at"]
  end

  def lambda_mw(env = {}, app = @app)
    st = I::State.new(env: {"HAYAOKI_INSITU_OUT" => @out, "AWS_LAMBDA_FUNCTION_NAME" => "f"}.merge(env), load_ms: I::Clock.now_ms)
    [I::Middleware.new(app, st), st]
  end

  # Lambda freezes the environment once the response is out, so the line must not wait for the body.
  def test_lambda_emits_when_the_app_returns
    iterated = closed = false
    body = Object.new
    body.define_singleton_method(:each) { |&b| iterated = true; b.call("ok") }
    body.define_singleton_method(:close) { closed = true }
    mw, st = lambda_mw({}, ->(_env) { [201, {}, body] })
    status, _, got = mw.call("PATH_INFO" => "/")
    assert_equal 201, status
    assert_same body, got
    refute iterated
    refute closed
    assert_equal 1, lines.size
    l = lines[0]
    assert_equal "ok", l["status"]
    assert_equal "app_return", l["first_request"]["end_at"]
    assert_equal 201, l["first_request"]["status"]
    assert_kind_of Integer, l["phases_ms"]["first_request"]
    refute st.first_request_incomplete?
    got.each { nil }
    got.close
    get("/x", mw)
    assert_equal 1, lines.size
  end

  def test_lambda_body_that_raises_keeps_the_line
    body = Object.new
    body.define_singleton_method(:each) { |&_b| raise "stream broke" }
    mw, = lambda_mw({}, ->(_env) { [200, {}, body] })
    got = mw.call("PATH_INFO" => "/")[2]
    assert_raises(RuntimeError) { got.each { nil } }
    assert_equal %w[ok], lines.map { _1["status"] }
  end

  def test_lambda_probe_is_still_ignored
    mw, = lambda_mw("AWS_LWA_READINESS_CHECK_PATH" => "/ready")
    get("/ready", mw)
    assert_empty lines
    get("/", mw)
    assert_equal 1, lines[0]["first_request"]["probe_hits"]
  end

  def test_emit_at
    at = ->(env) { I::State.new(env: env, load_ms: 1.0).emit_at }
    assert_equal "body_close", at.({})
    assert_equal "body_close", at.("AWS_LAMBDA_FUNCTION_NAME" => "")
    assert_equal "app_return", at.("AWS_LAMBDA_FUNCTION_NAME" => "f")
    assert_equal "body_close", at.("AWS_LAMBDA_FUNCTION_NAME" => "f", "K_SERVICE" => "s") # as Platform.kind
    assert_equal "body_close", at.("AWS_LAMBDA_FUNCTION_NAME" => "f", "HAYAOKI_INSITU_EMIT_AT" => "body_close")
    assert_equal "app_return", at.("HAYAOKI_INSITU_EMIT_AT" => "app_return")
    assert_equal "app_return", at.("AWS_LAMBDA_FUNCTION_NAME" => "f", "HAYAOKI_INSITU_EMIT_AT" => "bogus")
  end

  def test_emit_at_override_off_lambda
    st = I::State.new(env: {"HAYAOKI_INSITU_OUT" => @out, "HAYAOKI_INSITU_EMIT_AT" => "app_return"}, load_ms: I::Clock.now_ms)
    I::Middleware.new(@app, st).call("PATH_INFO" => "/")
    assert_equal "app_return", lines[0]["first_request"]["end_at"]
  end

  def test_app_exception_is_recorded_and_reraised
    assert_raises(RuntimeError) { @mw.call("PATH_INFO" => "/raise") }
    assert_equal 500, lines[0]["first_request"]["status"]
    assert_equal "app_raise", lines[0]["first_request"]["end_at"]
    assert_nil lines[0]["first_request"]["route"]
  end

  def test_new_features_grouped
    lib = Dir.mktmpdir("hayaoki-lazy")
    File.write(File.join(lib, "hayaoki_lazy_a.rb"), "")
    app = ->(env) { require File.join(lib, "hayaoki_lazy_a.rb"); [204, {}, []] }
    get("/", I::Middleware.new(app, @state))
    fr = lines[0]["first_request"]
    assert_equal 1, fr["new_features"]
    assert_equal [["<other>", 1]], fr["new_by_group"]
  ensure
    FileUtils.rm_rf(lib) if lib
  end

  def test_only_one_thread_wins_the_first_request
    q = Queue.new
    app = ->(_env) { q.pop; [200, {}, ["ok"]] }
    mw = I::Middleware.new(app, @state)
    threads = 8.times.map { Thread.new { get("/", mw) } }
    sleep 0.05
    8.times { q << 1 }
    threads.each(&:join)
    assert_equal 1, lines.size
  end

  # Non-Rails Rack app: `use Hayaoki::Insitu::Middleware` picks up Insitu.state.
  def test_usable_with_rack_builder
    require "rack/builder"
    saved = I.state
    I.instance_variable_set(:@state, @state)
    app = @app
    built = ::Rack::Builder.new do
      use Hayaoki::Insitu::Middleware
      run app
    end.to_app
    get("/up", built)
    get("/", built)
    assert_equal 1, lines.size
    assert_equal 1, lines[0]["first_request"]["probe_hits"]
  ensure
    I.instance_variable_set(:@state, saved)
  end

  def test_nil_state_is_pass_through
    mw = I::Middleware.new(@app, nil)
    assert_equal 200, get("/", mw)[0]
    assert_empty lines
  end

  def test_internal_error_does_not_reach_the_app
    st = @state
    def st.claim_first_request! = raise("internal")
    I.instance_variable_set(:@warned, false)
    _, err = capture_io { assert_equal 200, get("/")[0] }
    assert_match(/hayaoki insitu/, err)
    assert_equal 200, get("/")[0]
  end
end
