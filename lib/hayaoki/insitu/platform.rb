# frozen_string_literal: true

module Hayaoki
  module Insitu
    module Platform
      module_function

      # Verified in the design: K_SERVICE, K_REVISION, K_CONFIGURATION (Cloud Run).
      # UNVERIFIED against the AWS env-var reference (phase2.md §3.1): AWS_LAMBDA_FUNCTION_NAME,
      # AWS_LAMBDA_FUNCTION_VERSION, AWS_LAMBDA_FUNCTION_MEMORY_SIZE,
      # AWS_LAMBDA_INITIALIZATION_TYPE, AWS_LAMBDA_LOG_STREAM_NAME, AWS_LWA_READINESS_CHECK_PATH.
      def kind(env = ENV)
        if present?(env["K_SERVICE"]) then "cloud_run"
        elsif present?(env["AWS_LAMBDA_FUNCTION_NAME"]) then "lambda"
        else "generic"
        end
      end

      # The "platform" object of the log line (string keys, nil values dropped except kind).
      def fields(env = ENV)
        h =
          case kind(env)
          when "cloud_run"
            {"service" => env["K_SERVICE"], "revision" => env["K_REVISION"], "configuration" => env["K_CONFIGURATION"]}
          when "lambda"
            mem = env["AWS_LAMBDA_FUNCTION_MEMORY_SIZE"].to_s
            {"function" => env["AWS_LAMBDA_FUNCTION_NAME"], "version" => env["AWS_LAMBDA_FUNCTION_VERSION"],
             "memory_mb" => mem.match?(/\A\d+\z/) ? mem.to_i : nil,
             "init_type" => env["AWS_LAMBDA_INITIALIZATION_TYPE"], "log_stream" => env["AWS_LAMBDA_LOG_STREAM_NAME"]}
          else {}
          end
        {"kind" => kind(env)}.merge(h.reject { |_, v| v.nil? || v == "" })
      end

      # §2.2: HAYAOKI_INSITU_IGNORE_PATHS, default "/up" + AWS_LWA_READINESS_CHECK_PATH
      def ignore_paths(env = ENV)
        if env.key?("HAYAOKI_INSITU_IGNORE_PATHS")
          env["HAYAOKI_INSITU_IGNORE_PATHS"].split(",").map(&:strip).reject(&:empty?)
        else
          ["/up", env["AWS_LWA_READINESS_CHECK_PATH"]].select { present?(_1) }.uniq
        end
      end

      def present?(v) = !v.nil? && !v.empty?
    end
  end
end
