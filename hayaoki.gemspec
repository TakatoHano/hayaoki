# frozen_string_literal: true

require_relative "lib/hayaoki/version"

Gem::Specification.new do |spec|
  spec.name = "hayaoki"
  spec.version = Hayaoki::VERSION
  spec.authors = ["Takato Hano"]
  spec.summary = "Find out where your Rails app spends its boot time, and what to change"
  spec.description = "hayaoki boot-report boots a Rails app in a child process with a probe and breaks boot time down by gem, initializer, on_load hook and eager loading, then suggests measured fixes. Built for cold starts on serverless and containers."
  spec.homepage = "https://github.com/TakatoHano/hayaoki"
  spec.license = "MIT"
  spec.metadata = {
    "source_code_uri" => "https://github.com/TakatoHano/hayaoki",
    "changelog_uri" => "https://github.com/TakatoHano/hayaoki/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = Dir["exe/*"].map { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
