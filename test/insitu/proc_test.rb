# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/proc"

class InsituProcTest < Minitest::Test
  P = Hayaoki::Insitu::ProcFS
  # fields after comm: state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime ... starttime(22)
  def stat(comm) = "42 (#{comm}) S 1 42 42 0 -1 4194560 100 0 0 0 150 30 0 0 20 0 5 0 987654 1000 200 18446744073709551615"

  def test_parse_plain
    s = P.parse_stat(stat("ruby"))
    assert_equal({pid: 42, comm: "ruby", state: "S", ppid: 1, majflt: 0, utime: 150, stime: 30, starttime: 987654}, s)
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

  def test_runq_wait_ms
    # /proc/self/schedstat: on-CPU ns, run-queue wait ns, timeslices
    assert_in_delta 987.654321, P.runq_wait_ms("123456789 987654321 42\n"), 1e-9
    assert_equal 0.0, P.runq_wait_ms("5 0 1\n")
    ["", "garbage\n", "123\n", "1 x 2\n", "1 -5 2\n", "/nonexistent/schedstat"].each { assert_nil P.runq_wait_ms(_1), _1.inspect }
  end

  def test_majflt
    assert_equal 0, P.majflt(stat("ruby"))
    assert_equal 321, P.majflt("42 (a b) c) S 1 42 42 0 -1 4194560 100 0 321 7 150 30 0 0 20 0 5 0 987654 1000 200 1\n")
    ["", "garbage\n", "1 (x) S 1 2\n", "/nonexistent/stat"].each { assert_nil P.majflt(_1), _1.inspect }
  end

  def test_io_bytes
    io = "rchar: 52428800\nwchar: 1024\nsyscr: 900\nsyscw: 3\nread_bytes: 4096000\nwrite_bytes: 0\ncancelled_write_bytes: 0\n"
    assert_equal({read_bytes: 4_096_000, rchar: 52_428_800}, P.io_bytes(io))
    # overlay / FUSE: read_bytes stays 0 although files were read
    assert_equal({read_bytes: 0, rchar: 10}, P.io_bytes("rchar: 10\nread_bytes: 0\n"))
    assert_equal({read_bytes: nil, rchar: 10}, P.io_bytes("rchar: 10\nwchar: 1\n"))
    ["", "garbage\n", "read_bytes: x\n", "/nonexistent/io"].each { assert_nil P.io_bytes(_1), _1.inspect }
  end

  def test_steal_ms
    # cpu user nice system idle iowait irq softirq steal guest guest_nice
    text = "cpu  100 0 50 9000 20 0 3 250 0 0\ncpu0 50 0 25 4500 10 0 1 125 0 0\nintr 1 2 3\n"
    assert_equal 2500.0, P.steal_ms(text)
    assert_equal 1000.0, P.steal_ms(text, clk_tck: 250)
    assert_equal 0.0, P.steal_ms("cpu  1 2 3 4 5 6 7 0\n")
    # kernels before 2.6.11 have no steal column
    ["", "garbage\n", "cpu  1 2 3 4 5 6 7\n", "cpu  1 2 3 4 5 6 7 x\n", "cpu0 1 2 3 4 5 6 7 8\n", "/nonexistent/stat"].each { assert_nil P.steal_ms(_1), _1.inspect }
    assert_nil P.steal_ms(text, clk_tck: 0)
  end

  # only the first line of /proc/stat is read (the file is long on many-CPU hosts)
  def test_steal_ms_reads_first_line_of_a_file
    require "tmpdir"
    Dir.mktmpdir do |d|
      path = File.join(d, "stat")
      File.write(path, "cpu  100 0 50 9000 20 0 3 250 0 0\n#{"x" * 100_000}\n")
      assert_equal 2500.0, P.steal_ms(path)
      File.write(path, "intr 1 2 3\ncpu  100 0 50 9000 20 0 3 250 0 0\n")
      assert_nil P.steal_ms(path)
    end
  end

  def test_psi_some_ms
    io = "some avg10=0.00 avg60=1.25 avg300=0.40 total=4812345\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=99\n"
    assert_in_delta 4812.345, P.psi_some_ms("io", io), 1e-9
    assert_equal 0.0, P.psi_some_ms("cpu", "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
    ["", "garbage\n", "full avg10=0.00 total=5\n", "some avg10=0.00\n", "/nonexistent/pressure/io"].each { assert_nil P.psi_some_ms("io", _1), _1.inspect }
  end

  WAIT_KEYS = %w[majflt io_read_bytes io_rchar steal_ms psi_io_some_ms psi_cpu_some_ms].freeze

  def test_wait_counters_keys_and_never_raises
    w = P.wait_counters
    assert_equal WAIT_KEYS, w.keys
    w.each_value { assert(_1.nil? || _1 >= 0) }
    assert_equal [nil] * 6, w.values unless RUBY_PLATFORM.include?("linux")
    assert_operator w["majflt"], :>=, 0 if RUBY_PLATFORM.include?("linux")
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
    assert_nil P.runq_wait_ms
    assert_nil P.majflt
    assert_nil P.io_bytes
    assert_nil P.steal_ms
    assert_nil P.psi_some_ms("io")
  end
end
