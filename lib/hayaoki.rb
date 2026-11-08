# frozen_string_literal: true

require_relative "hayaoki/version"

# Hayaoki - Rails cold-start toolkit
module Hayaoki
  class Error < StandardError; end
end

module Hayaoki
  autoload :CLI, "hayaoki/cli"

  module BootReport
    autoload :Runner, "hayaoki/boot_report/runner"
    autoload :RunResult, "hayaoki/boot_report/runner"
    autoload :RunError, "hayaoki/boot_report/runner"
    autoload :Aggregator, "hayaoki/boot_report/aggregator"
    autoload :Report, "hayaoki/boot_report/report"
    autoload :Advisor, "hayaoki/boot_report/advisor"
    autoload :Suggestion, "hayaoki/boot_report/advisor"

    module Formatters
      autoload :Text, "hayaoki/boot_report/formatters/text"
      autoload :Json, "hayaoki/boot_report/formatters/json"
      autoload :Speedscope, "hayaoki/boot_report/formatters/speedscope"
    end
  end
end
