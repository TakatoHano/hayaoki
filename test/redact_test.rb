# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "hayaoki/redact"

class RedactTest < Minitest::Test
  def test_gem_path_via_specs
    specs = [["rack", "/opt/x/rack-3.0.0"], ["rack-session", "/opt/x/rack-session-2.0.0"]]
    assert_equal "<gem:rack>", Hayaoki::Redact.group_for("/opt/x/rack-3.0.0/lib/rack.rb", specs, "/app")
    assert_equal "<gem:rack-session>", Hayaoki::Redact.group_for("/opt/x/rack-session-2.0.0/lib/a.rb", specs, "/app")
  end

  def test_gem_path_via_regex
    assert_equal "<gem:foo>", Hayaoki::Redact.group_for("/u/x/gems/foo-1.2.3/lib/foo.rb", [], "/app")
  end

  def test_app_and_realpath
    Dir.mktmpdir do |d|
      real = File.realpath(d)
      assert_equal "<app>", Hayaoki::Redact.group_for(File.join(d, "app/a.rb"), [], d)
      assert_equal "<app>", Hayaoki::Redact.group_for(File.join(real, "app/a.rb"), [], d)
      assert_equal "<other>", Hayaoki::Redact.group_for("#{d}x/a.rb", [], d)
      assert_equal "<app>/app/a.rb", Hayaoki::Redact.redact_string("#{real}/app/a.rb", app_dir: d, home: "/nohome")
    end
  end

  def test_home_dir
    assert_equal "~/x/y.rb", Hayaoki::Redact.redact_string("/home/me/x/y.rb", home: "/home/me")
    assert_equal "/home/meh/y", Hayaoki::Redact.redact_string("/home/meh/y", home: "/home/me")
  end

  def test_unknown_and_stdlib
    assert_equal "<other>", Hayaoki::Redact.group_for("/somewhere/else.rb", [], "/app")
    lib = File.join(RbConfig::CONFIG["rubylibdir"], "set.rb")
    assert_equal "<stdlib>", Hayaoki::Redact.group_for(lib, [], "/app")
  end
end
