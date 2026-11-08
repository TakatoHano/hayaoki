# frozen_string_literal: true

# hayaoki in-situ cold-start logging. Design: docs/design/phase2.md
#
#   # config/boot.rb
#   require "bundler/setup"
#   require "hayaoki/insitu"   # before bootsnap/setup
#
# On in production (RAILS_ENV / RACK_ENV), HAYAOKI_INSITU=0 turns it off, =1 forces it on.
# When off, this file defines only Hayaoki::Insitu.enabled? and returns.
# Writes one JSON line per serving process after the first non-probe response (fallback: at_exit).
# Never raises into the app: internal errors print one line to stderr and the app goes on.

module Hayaoki
  module Insitu
    OFF = %w[0 false off no].freeze
    ON = %w[1 true on yes].freeze

    def self.enabled?(env = ENV)
      v = env["HAYAOKI_INSITU"].to_s.strip.downcase
      return false if OFF.include?(v)
      return true if ON.include?(v)
      e = env["RAILS_ENV"]
      e = env["RACK_ENV"] if e.nil? || e.empty?
      e == "production"
    end
  end
end

return unless Hayaoki::Insitu.enabled?
return if defined?(Hayaoki::Insitu::STARTED)

require_relative "insitu/clock"
Hayaoki::Insitu::LOAD_MS = Hayaoki::Insitu::Clock.now_ms
require_relative "insitu/state"
require_relative "insitu/hooks" # middleware / emitter / platform / redact load later, when used

Hayaoki::Insitu.start!(load_ms: Hayaoki::Insitu::LOAD_MS)
Hayaoki::Insitu::STARTED = true
