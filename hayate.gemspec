# frozen_string_literal: true

require_relative "lib/hayate/version"

Gem::Specification.new do |spec|
  spec.name = "hayate"
  spec.version = Hayate::VERSION
  spec.authors = ["Takato Hano"]
  spec.summary = "Rails cold-start toolkit"
  spec.description = "Rails cold-start toolkit: hayate boot-report measures and reports where Rails boot time goes."
  spec.homepage = "https://github.com/TakatoHano/hayate"
  spec.license = "MIT"
  spec.metadata = {
    "source_code_uri" => "https://github.com/TakatoHano/hayate",
    "changelog_uri" => "https://github.com/TakatoHano/hayate/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = Dir["exe/*"].map { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
