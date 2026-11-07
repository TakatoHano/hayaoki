require_relative "boot"
require "rails"
require "action_controller/railtie"
Bundler.require(*Rails.groups)
module MinApp
  class Application < Rails::Application
    config.load_defaults 8.0 if config.respond_to?(:load_defaults) && Rails::VERSION::MAJOR >= 8
    config.eager_load = true
    config.secret_key_base = "x" * 64
    config.hosts.clear
    config.logger = Logger.new(nil)
  end
end
