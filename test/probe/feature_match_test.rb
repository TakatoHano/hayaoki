# frozen_string_literal: true

require "test_helper"

# require に渡された名前と $LOADED_FEATURES の要素の対応付け。
# 一致しないと $LOADED_FEATURES.last にフォールバックするので、1 スレッドでは間違いに気付きにくい。
class ProbeFeatureMatchTest < Minitest::Test
  include ProbeHelper

  CASES = [
    # [feature, name, expected]
    ["/app/tmp/th3_outer.rb", "./th3_outer", true],
    ["/app/tmp/th3_outer.rb", "./th3_outer.rb", true],
    ["/app/tmp/th5_outer.rb", "./th3_outer", false],
    ["/app/tmp/xth3_outer.rb", "./th3_outer", false],
    ["/app/lib/sub/x.rb", "./sub/x", true],
    ["/app/lib/x.rb", "../lib/x", true],
    ["/app/lib/x.rb", "../../app/lib/x.rb", true],
    ["/app/other/x.rb", "../lib/x", false],
    ["/gems/foo-1.0/lib/foo.rb", "foo", true],
    ["/gems/foo-1.0/lib/foo/bar.rb", "foo/bar", true],
    ["/gems/foo-1.0/lib/xfoo.rb", "foo", false],
    ["/gems/foo-1.0/lib/foo.so", "foo", true],
    ["/gems/foo-1.0/lib/foo.rb", "/gems/foo-1.0/lib/foo", true],
    ["/gems/foo-1.0/lib/foo.rb", "/gems/foo-1.0/lib/foo.rb", true],
    ["/gems/foo-1.0/lib/foobar.rb", "/gems/foo-1.0/lib/foo", false],
    ["prism/prism.so", "prism/prism", true],
    ["xprism/prism.so", "prism/prism", false],
    ["/ruby/lib/arm64-darwin/psych.bundle", "psych.so", true],
    ["/ruby/lib/x86_64-linux/psych.so", "psych.so", true],
    ["/ruby/lib/psych.rb", "psych.so", false],
  ].freeze

  def test_feature_match
    code = "#{CASES.inspect}.each { |f, n, _| puts Hayaoki::Probe.feature_match?(f, n) }"
    r = run_probe(code)
    got = r.out.lines.map { _1.strip == "true" }
    CASES.each_with_index do |(f, n, want), i|
      assert_equal want, got[i], "feature_match?(#{f.inspect}, #{n.inspect})"
    end
  end

  # 他スレッドのファイルが末尾にあっても、自分の feature を探し当てる
  def test_resolve_feature_does_not_take_another_threads_last_feature
    code = '$LOADED_FEATURES << "/app/tmp/th3_outer.rb" << "/app/tmp/th5_outer.rb"; ' \
           'puts Hayaoki::Probe.resolve_feature("./th3_outer")'
    assert_equal "/app/tmp/th3_outer.rb", run_probe(code).out.strip
  end
end
