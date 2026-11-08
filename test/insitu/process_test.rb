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
