# frozen_string_literal: true

require "test_helper"

class ProbeBootEndTest < Minitest::Test
  include ProbeHelper

  def test_require_inside_at_exit_does_not_extend_boot_end
    r = run_probe('require "./t_main"; at_exit { sleep 0.2; require "./t_leaf" }')
    rep = r.report
    main = rep.feature("t_main.rb").first
    assert_equal main.t1, rep["boot_end_us"]
    assert_operator rep["exit_us"] - rep["boot_end_us"], :>=, 150_000
  end
end
