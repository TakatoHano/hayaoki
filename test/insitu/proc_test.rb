# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/proc"

class InsituProcTest < Minitest::Test
  P = Hayaoki::Insitu::ProcFS
  # fields after comm: state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime ... starttime(22)
  def stat(comm) = "42 (#{comm}) S 1 42 42 0 -1 4194560 100 0 0 0 150 30 0 0 20 0 5 0 987654 1000 200 18446744073709551615"

  def test_parse_plain
    s = P.parse_stat(stat("ruby"))
    assert_equal({pid: 42, comm: "ruby", state: "S", ppid: 1, utime: 150, stime: 30, starttime: 987654}, s)
  end

  def test_parse_comm_with_spaces_and_parens
    s = P.parse_stat(stat("my (weird) proc"))
    assert_equal "my (weird) proc", s[:comm]
    assert_equal 987654, s[:starttime]
  end

  def test_parse_failures
    [nil, "", "garbage", "1 (x) S 1 2", "x (a) S #{"1 " * 30}"].each { assert_nil P.parse_stat(_1) }
  end

  def test_self_stat_from_string_and_missing_path
    assert_equal 987654, P.self_stat(stat("ruby"))[:starttime]
    assert_nil P.self_stat("/nonexistent/stat")
  end

  def test_rss_kb
    assert_equal 214000, P.rss_kb("Name:\truby\nVmRSS:\t  214000 kB\nThreads:\t1\n")
    assert_nil P.rss_kb("Name:\truby\n")
  end

  def test_uptime_ms
    assert_equal 2600, P.uptime_ms("2.60 10.5\n")
    assert_nil P.uptime_ms("abc\n")
  end

  def test_pid1_age
    pid1 = "1 (init) S 0 1 1 0 -1 0 0 0 0 0 1 1 0 0 20 0 1 0 100 1 1 1\n"
    assert_equal 2600 - 1000, P.pid1_age_ms(pid1, "2.6 0\n", clk_tck: 100, pid: 7)
    assert_nil P.pid1_age_ms(pid1, "2.6 0\n", clk_tck: 100, pid: 1)
    assert_nil P.pid1_age_ms("junk\n", "2.6 0\n", pid: 7)
  end

  def test_real_proc
    skip "needs Linux /proc" unless RUBY_PLATFORM.include?("linux")
    assert_operator P.self_stat[:starttime], :>, 0
    assert_operator P.rss_kb, :>, 0
    assert_operator P.uptime_ms, :>, 0
  end

  def test_non_linux_returns_nil
    skip "Linux only" if RUBY_PLATFORM.include?("linux")
    assert_nil P.self_stat
    assert_nil P.uptime_ms
  end
end
