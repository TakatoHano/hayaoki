# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/hooks"
begin
  require "rack/body_proxy"
rescue LoadError
  nil
end

# at_exit fallback and fork handling (Puma cluster: the master forks workers after boot).
class InsituProcessTest < Minitest::Test
  I = Hayaoki::Insitu

  def setup
    @dir = Dir.mktmpdir("hayaoki-proc")
    @out = File.join(@dir, "log")
    @state = I::State.new(env: {"HAYAOKI_INSITU_OUT" => @out}, load_ms: I::Clock.now_ms)
    @state.mark(:initialize_end)
    @saved = I.state
    I.instance_variable_set(:@state, @state)
  end

  def teardown
    I.instance_variable_set(:@state, @saved)
    FileUtils.rm_rf(@dir)
  end

  def lines = File.exist?(@out) ? File.readlines(@out).map { JSON.parse(_1) } : []

  # Stand-in for Rake (real rake stays unloaded so other tests see no ::Rake).
  def with_fake_rake
    skip "real rake is loaded" if defined?(::Rake)
    rake = Module.new
    class << rake
      attr_accessor :application
    end
    rake.application = Struct.new(:top_level_tasks).new([])
    Object.const_set(:Rake, rake)
    yield rake
  ensure
    Object.send(:remove_const, :Rake) if rake && Object.const_defined?(:Rake, false) && Object.const_get(:Rake).equal?(rake)
  end

  def fake_app
    mw = Object.new
    def mw.insert_before(*) = nil
    config = Struct.new(:middleware, :eager_load).new(mw, false)
    Struct.new(:config).new(config)
  end

  def with_program(name)
    saved = I.instance_variable_get(:@program)
    I.instance_variable_set(:@program, name)
    yield
  ensure
    I.instance_variable_set(:@program, saved)
  end

  def test_server_without_request_emits_no_request
    I.at_exit!
    assert_equal ["no_request"], lines.map { _1["status"] }
  end

  def test_rake_process_is_quiet_but_boot_error_is_not
    rake = Module.new
    app = Struct.new(:top_level_tasks).new(["assets:precompile"])
    rake.define_singleton_method(:application) { app }
    Object.const_set(:Rake, rake)
    refute I.server_process?
    I.at_exit!
    assert_empty lines
    @state.boot_error = "LoadError"
    I.at_exit!
    assert_equal ["boot_error"], lines.map { _1["status"] }
  ensure
    Object.send(:remove_const, :Rake) if Object.const_defined?(:Rake, false) && Object.const_get(:Rake).equal?(rake)
  end

  # `bin/rails db:prepare`: RakeCommand runs the task (and initialize!) inside
  # Rake.with_application, which puts back an empty Rake.application before at_exit.
  def test_rails_task_is_quiet_after_rake_application_is_restored
    with_fake_rake do |rake|
      outer = rake.application
      rake.application = Struct.new(:top_level_tasks).new(["db:prepare"])
      saved = I.instance_variable_get(:@middleware_inserted)
      I.instance_variable_set(:@middleware_inserted, true)
      I.before_initialize(fake_app)
      I.instance_variable_set(:@middleware_inserted, saved)
      rake.application = outer
      assert I.server_process?
      I.at_exit!
      assert_empty lines
    end
  end

  def test_ready_mode_does_not_emit_in_a_rake_task
    st = I::State.new(env: {"HAYAOKI_INSITU_OUT" => @out, "HAYAOKI_INSITU_EMIT" => "ready"}, load_ms: I::Clock.now_ms)
    I.instance_variable_set(:@state, st)
    with_fake_rake do |rake|
      rake.application = Struct.new(:top_level_tasks).new(["assets:precompile"])
      I.before_initialize(fake_app)
      I.after_initialize
    end
    assert_empty lines
  end

  def test_ready_mode_emits_in_a_server
    st = I::State.new(env: {"HAYAOKI_INSITU_OUT" => @out, "HAYAOKI_INSITU_EMIT" => "ready"}, load_ms: I::Clock.now_ms)
    I.instance_variable_set(:@state, st)
    I.before_initialize(fake_app)
    I.after_initialize
    assert_equal ["ok"], lines.map { _1["status"] }
  end

  def test_job_runner_program_is_quiet
    %w[sidekiq jobs good_job].each do |prog|
      with_program(prog) { refute I.server_process?, prog }
    end
    with_program("sidekiq") { I.at_exit! }
    assert_empty lines
    with_program("puma") { assert I.server_process? }
  end

  def test_unfinished_first_request_is_incomplete_even_in_a_forking_parent
    @state.forked_parent!
    @state.mark(:first_request_start)
    I.at_exit!
    l = lines
    assert_equal ["incomplete"], l.map { _1["status"] }
    assert_nil l[0]["phases_ms"]["to_first_response"]
  end

  # Puma fork_worker: worker 0 serves, then forks the other workers. Each child must still
  # write its own first-request line (not inherit "done" and fall back to no_request).
  def test_child_forked_after_the_first_request_emits_its_own_line
    skip "needs fork and Process._fork" unless Process.respond_to?(:fork) && Process.respond_to?(:_fork)
    skip "rack is not installed" unless defined?(::Rack::BodyProxy)
    Process.singleton_class.prepend(I::Hooks::ForkHook)
    require "hayaoki/insitu/middleware"
    mw = I::Middleware.new(->(_env) { [200, {}, ["ok"]] }, @state)
    serve = -> { b = mw.call("PATH_INFO" => "/")[2]; b.close if b.respond_to?(:close) }
    serve.call
    pid = fork do
      serve.call
      I.at_exit!
    ensure
      exit!(0)
    end
    Process.wait(pid)
    l = lines
    assert_equal %w[ok ok], l.map { _1["status"] }
    child = l.find { _1["pid"] == pid }
    assert child, "child line"
    assert_equal true, child["worker"]
    assert_operator child["marks_ms"]["forked"], :<=, child["marks_ms"]["first_request_start"]
    refute_nil child["phases_ms"]["to_ready"]
  end

  def test_forking_parent_is_quiet_and_each_child_emits_once
    skip "needs fork and Process._fork" unless Process.respond_to?(:fork) && Process.respond_to?(:_fork)
    skip "rack is not installed" unless defined?(::Rack::BodyProxy)
    Process.singleton_class.prepend(I::Hooks::ForkHook)
    require "hayaoki/insitu/middleware"
    mw = I::Middleware.new(->(_env) { [200, {}, ["ok"]] }, @state)
    pids = 2.times.map do
      fork do
        2.times do
          body = mw.call("PATH_INFO" => "/")[2]
          body.close if body.respond_to?(:close)
        end
        I.at_exit!
      ensure
        exit!(0) # skip minitest's at_exit in the child
      end
    end
    pids.each { Process.wait(_1) }
    I.at_exit! # parent: forked children, never served
    l = lines
    assert_equal 2, l.size
    assert_equal pids.sort, l.map { _1["pid"] }.sort
    l.each do |x|
      assert_equal "ok", x["status"]
      assert_equal true, x["worker"]
      assert_kind_of Integer, x["marks_ms"]["forked"]
      assert_operator x["marks_ms"]["forked"], :<=, x["marks_ms"]["first_request_start"]
    end
    assert_equal 1, l.map { _1["id"] }.uniq.size
  end
end
