# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "hayaoki/boot_report/gemfile"

class GemfileTest < Minitest::Test
  G = Hayaoki::BootReport::Gemfile

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

  def test_if_block_inside_group_does_not_pop_group
    src = "group :development do\n  if RUBY_PLATFORM =~ /darwin/\n    gem \"terminal-notifier\"\n  end\n  gem \"pry-rails\"\nend\ngem \"rails\"\n"
    e = G.parse(src)
    assert_equal %w[development], e["terminal-notifier"].groups
    assert_equal %w[development], e["pry-rails"].groups
    assert_equal [], e["rails"].groups
  end

  def test_begin_and_modifier_forms
    src = "group :development, :test do\n  begin\n    gem \"a\"\n  end\n  gem \"b\" if foo\n  gem \"c\"\nend\ngem \"d\"\n"
    e = G.parse(src)
    assert_equal %w[development test], e["b"].groups
    assert_equal %w[development test], e["c"].groups
    assert_equal [], e["d"].groups
  end

  def test_one_line_group_block_does_not_leak
    e = G.parse("group :test do gem \"byebug\" end\ngem \"later\"\n")
    assert_equal %w[test], e["byebug"].groups
    assert_equal [], e["later"].groups
  end

  def test_duplicate_declarations_merge
    e = G.parse("group :test do\n  gem \"x\"\nend\ngem \"x\"\ngem \"y\", group: :test\ngem \"y\", group: :development\n")
    assert_equal [], e["x"].groups
    assert_equal %w[test development], e["y"].groups
  end

  def test_percent_literals_and_continuation_lines
    src = "group %i[development test] do\n  gem \"a\"\nend\ngem \"b\", groups: %w[test ci]\n" \
          "gem \"c\", require: %w[c/x c/y]\ngem \"faker\",\n  group: :development\ngem \"d\", \\\n  group: :test\n"
    e = G.parse(src)
    assert_equal %w[development test], e["a"].groups
    assert_equal %w[test ci], e["b"].groups
    assert_equal %w[c/x c/y], e["c"].require
    assert_equal %w[development], e["faker"].groups
    assert_equal %w[test], e["d"].groups
  end

  def test_eval_gemfile_literal_and_glob_inherit_groups
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "extra.gemfile"), "gem \"from-extra\"\n")
      FileUtils.mkdir_p(File.join(dir, "plugins/a"))
      File.write(File.join(dir, "plugins/a/PluginGemfile"), "gem \"from-plugin\"\n")
      File.write(File.join(dir, "loop.gemfile"), "eval_gemfile \"loop.gemfile\"\ngem \"looped\"\n")
      src = "eval_gemfile \"extra.gemfile\"\ngroup :test do\n  eval_gemfile \"loop.gemfile\"\nend\n" \
            "Dir.glob(File.expand_path(\"plugins/*/{Gemfile,PluginGemfile}\", __dir__)).each { |f| eval_gemfile f }\n" \
            "gem \"after\"\n"
      e = G.parse(src, dir: dir)
      assert_equal [], e["from-extra"].groups
      assert_equal [], e["from-plugin"].groups
      assert_equal %w[test], e["looped"].groups
      assert_equal [], e["after"].groups
      assert_empty G.parse(src)["from-extra"].to_a
    end
  end
end
