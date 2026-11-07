# frozen_string_literal: true

require_relative "lib/hayate/version"

Gem::Specification.new do |spec|
  spec.name = "hayate"
  spec.version = Hayate::VERSION
  spec.authors = ["hayate contributors"]
  spec.summary = "Rails cold-start toolkit"
  spec.description = "hayate measures and reports where Rails boot time goes (boot-report)."
  spec.homepage = "https://github.com/hayate-rb/hayate"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README*", "LICENSE*"]
  spec.bindir = "exe"
  spec.executables = Dir["exe/*"].map { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
