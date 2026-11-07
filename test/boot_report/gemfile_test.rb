# frozen_string_literal: true

require "test_helper"
require "hayate/boot_report/gemfile"

class GemfileTest < Minitest::Test
  G = Hayate::BootReport::Gemfile

  def test_parses_groups_and_require
    src = <<~G
      source "https://rubygems.org"
      gem "rails", "~> 8.0" # comment
      gem "bootsnap", require: false
      gem "foo", require: "foo/bar"
      gem 'bar', :require => ['a', 'b']
      group :development, :test do
        gem "debug"
      end
      gem "x", group: :test
      gem "y", groups: [:a, :b]
    G
    e = G.parse(src)
    assert_equal [], e["rails"].groups
    assert_nil e["rails"].require
    assert_equal false, e["bootsnap"].require
    assert_equal ["foo/bar"], e["foo"].require
    assert_equal %w[a b], e["bar"].require
    assert_equal %w[development test], e["debug"].groups
    assert_equal %w[test], e["x"].groups
    assert_equal %w[a b], e["y"].groups
  end

  def test_block_end_tracking
    e = G.parse("group :test do\n  platforms :mri do\n    gem \"a\"\n  end\n  gem \"b\"\nend\ngem \"c\"\n")
    assert_equal %w[test], e["a"].groups
    assert_equal %w[test], e["b"].groups
    assert_equal [], e["c"].groups
  end
end
