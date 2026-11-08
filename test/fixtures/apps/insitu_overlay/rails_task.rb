# Copied over rails_min by test/insitu/integration_test.rb. Runs a Rake task the way
# `bin/rails db:prepare` does: Rails::Command falls back to RakeCommand, which runs the task
# (and initialize!) inside Rake.with_application.
APP_PATH = File.expand_path("config/application", __dir__)
require_relative "config/boot"
require "rails/command"
Rails::Command.invoke(ENV.fetch("TASK", "hayaoki:noop"), [])
