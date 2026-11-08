ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "hayaoki/insitu"
require "bootsnap/setup" unless ENV["NO_BOOTSNAP"]
