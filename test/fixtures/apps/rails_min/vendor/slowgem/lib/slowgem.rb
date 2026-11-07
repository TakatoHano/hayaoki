sleep 0.10
require_relative "slowgem/inner"
require "slowgem/other"
ActiveSupport.on_load(:action_controller) { sleep 0.04 } if defined?(ActiveSupport)
