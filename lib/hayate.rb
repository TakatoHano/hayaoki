# frozen_string_literal: true

require_relative "hayate/version"

# Hayate - Rails cold-start toolkit
module Hayate
  class Error < StandardError; end
end

module Hayate
  autoload :CLI, "hayate/cli"

  module BootReport
    autoload :Runner, "hayate/boot_report/runner"
    autoload :RunResult, "hayate/boot_report/runner"
    autoload :RunError, "hayate/boot_report/runner"
    autoload :Aggregator, "hayate/boot_report/aggregator"
    autoload :Report, "hayate/boot_report/report"
    autoload :Advisor, "hayate/boot_report/advisor"
    autoload :Suggestion, "hayate/boot_report/advisor"

    module Formatters
      autoload :Text, "hayate/boot_report/formatters/text"
      autoload :Json, "hayate/boot_report/formatters/json"
      autoload :Speedscope, "hayate/boot_report/formatters/speedscope"
    end
  end
end
