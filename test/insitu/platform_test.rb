# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/platform"

class InsituPlatformTest < Minitest::Test
  P = Hayaoki::Insitu::Platform

  def test_generic
    assert_equal "generic", P.kind({})
    assert_equal({"kind" => "generic"}, P.fields({}))
  end

  def test_cloud_run
    env = {"K_SERVICE" => "redmine", "K_REVISION" => "redmine-00012-abc", "K_CONFIGURATION" => "redmine"}
    assert_equal({"kind" => "cloud_run", "service" => "redmine", "revision" => "redmine-00012-abc", "configuration" => "redmine"}, P.fields(env))
  end

  def test_lambda
    env = {"AWS_LAMBDA_FUNCTION_NAME" => "f", "AWS_LAMBDA_FUNCTION_VERSION" => "$LATEST",
           "AWS_LAMBDA_FUNCTION_MEMORY_SIZE" => "1024", "AWS_LAMBDA_INITIALIZATION_TYPE" => "on-demand",
           "AWS_LAMBDA_LOG_STREAM_NAME" => "2026/11/08/[$LATEST]abc"}
    assert_equal({"kind" => "lambda", "function" => "f", "version" => "$LATEST", "memory_mb" => 1024,
                  "init_type" => "on-demand", "log_stream" => "2026/11/08/[$LATEST]abc",
                  "lwa_async_init" => false}, P.fields(env))
  end

  def test_lambda_lwa_async_init_true_only
    base = {"AWS_LAMBDA_FUNCTION_NAME" => "f"}
    assert_equal true, P.fields(base.merge("AWS_LWA_ASYNC_INIT" => "true"))["lwa_async_init"]
    assert_equal true, P.fields(base.merge("AWS_LWA_ASYNC_INIT" => " TRUE "))["lwa_async_init"]
    assert_equal false, P.fields(base.merge("AWS_LWA_ASYNC_INIT" => "false"))["lwa_async_init"]
    assert_equal false, P.fields(base.merge("AWS_LWA_ASYNC_INIT" => "1"))["lwa_async_init"]
    assert_equal false, P.fields(base.merge("AWS_LWA_ASYNC_INIT" => ""))["lwa_async_init"]
    refute P.fields({"K_SERVICE" => "s", "AWS_LWA_ASYNC_INIT" => "true"}).key?("lwa_async_init")
    refute_includes P.fields(base.merge("AWS_LWA_ASYNC_INIT" => "secret-value")).values.map(&:to_s), "secret-value"
  end

  def test_cloud_run_wins_and_empty_ignored
    assert_equal "cloud_run", P.kind({"K_SERVICE" => "s", "AWS_LAMBDA_FUNCTION_NAME" => "f"})
    assert_equal "generic", P.kind({"K_SERVICE" => ""})
    assert_equal({"kind" => "lambda", "function" => "f", "lwa_async_init" => false}, P.fields({"AWS_LAMBDA_FUNCTION_NAME" => "f", "AWS_LAMBDA_FUNCTION_MEMORY_SIZE" => "x"}))
  end

  def test_ignore_paths
    assert_equal ["/up"], P.ignore_paths({})
    assert_equal ["/up", "/ready"], P.ignore_paths({"AWS_LWA_READINESS_CHECK_PATH" => "/ready"})
    assert_equal ["/a", "/b"], P.ignore_paths({"HAYAOKI_INSITU_IGNORE_PATHS" => "/a, /b,"})
  end

  def test_default_env_does_not_raise
    assert_includes %w[cloud_run lambda generic], P.fields["kind"]
  end
end
