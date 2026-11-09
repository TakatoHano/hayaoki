# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "hayaoki/insitu/limits"

class InsituLimitsTest < Minitest::Test
  L = Hayaoki::Insitu::Limits

  def cg(files)
    Dir.mktmpdir do |d|
      files.each do |rel, body|
        FileUtils.mkdir_p(File.dirname(File.join(d, rel)))
        File.write(File.join(d, rel), body)
      end
      yield d
    end
  end

  def test_parse_cpu_max
    assert_equal 1.0, L.parse_cpu_max("100000 100000\n")
    assert_equal 2.0, L.parse_cpu_max("200000 100000")
    assert_equal 0.5, L.parse_cpu_max("50000 100000")
    assert_nil L.parse_cpu_max("max 100000")
    assert_nil L.parse_cpu_max("garbage")
    assert_nil L.parse_cpu_max("abc def")
    assert_nil L.parse_cpu_max("100 0")
    assert_nil L.parse_cpu_max("")
    assert_nil L.parse_cpu_max(nil)
  end

  def test_v2
    cg("cgroup.controllers" => "cpu memory", "cpu.max" => "200000 100000\n", "memory.max" => "1073741824\n") do |d|
      assert_equal "v2", L.cgroup(root: d)
      assert_equal 2.0, L.cpu_quota(root: d)
      assert_equal 1024, L.mem_max_mb(root: d)
    end
    cg("cgroup.controllers" => "cpu memory", "cpu.max" => "max 100000\n", "memory.max" => "max\n") do |d|
      assert_equal "v2", L.cgroup(root: d)
      assert_nil L.cpu_quota(root: d)
      assert_nil L.mem_max_mb(root: d)
    end
  end

  def test_v2_nested_path_keeps_tightest
    files = {"cgroup.controllers" => "cpu memory", "cpu.max" => "400000 100000", "memory.max" => "max",
             "a/cpu.max" => "max 100000", "a/memory.max" => "2147483648",
             "a/b/cpu.max" => "150000 100000", "a/b/memory.max" => "1073741824"}
    cg(files) do |d|
      own = "12:cpu:/ignored\n0::/a/b\n"
      assert_equal 1.5, L.cpu_quota(root: d, self_cgroup: own)
      assert_equal 1024, L.mem_max_mb(root: d, self_cgroup: own)
      assert_equal 4.0, L.cpu_quota(root: d, self_cgroup: "0::/\n")
      assert_nil L.mem_max_mb(root: d, self_cgroup: "0::/\n")
      assert_equal 4.0, L.cpu_quota(root: d, self_cgroup: "0::/missing/dir\n")
      assert_equal 4.0, L.cpu_quota(root: d, self_cgroup: "garbage")
      assert_equal "/a/b", L.own_path(own)
      assert_equal "/", L.own_path("0::/../etc\n")
    end
  end

  def test_v1
    cg("cpu/cpu.cfs_quota_us" => "-1\n", "cpu/cpu.cfs_period_us" => "100000\n") do |d|
      assert_equal "v1", L.cgroup(root: d)
      assert_nil L.cpu_quota(root: d)
    end
    cg("cpu/cpu.cfs_quota_us" => "50000\n", "cpu/cpu.cfs_period_us" => "100000\n",
       "memory/memory.limit_in_bytes" => "536870912\n") do |d|
      assert_equal 0.5, L.cpu_quota(root: d)
      assert_equal 512, L.mem_max_mb(root: d)
    end
    cg("cpu/cpu.cfs_quota_us" => "50000\n") do |d| # period missing
      assert_nil L.cpu_quota(root: d)
    end
  end

  def test_mem_sentinel_and_garbage
    assert_nil L.parse_mem("max")
    assert_nil L.parse_mem("9223372036854771712") # v1 "no limit"
    assert_nil L.parse_mem(((2**60)).to_s)
    assert_equal 1, L.parse_mem("1048576")
    assert_equal 256, L.parse_mem("268435456\n")
    assert_nil L.parse_mem("x")
    assert_nil L.parse_mem("0")
    assert_nil L.parse_mem(nil)
  end

  def test_missing_files
    Dir.mktmpdir do |d|
      assert_nil L.cgroup(root: d)
      assert_nil L.cpu_quota(root: d)
      assert_nil L.mem_max_mb(root: d)
    end
    assert_nil L.cgroup(root: "/nonexistent/hayaoki")
    assert_nil L.mem_max_mb(root: "/nonexistent/hayaoki")
  end

  def test_nproc
    assert_operator L.nproc, :>=, 1
  end

  def test_sandbox
    assert_equal "gvisor", L.sandbox("Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016\n")
    assert_equal "gvisor", L.sandbox("Linux version 4.4.0-x #1 SMP Sun Jan 10 15:06:54 PST 2016")
    assert_nil L.sandbox("Linux version 6.1.0-test (builder@host) #1 SMP\n")
    assert_nil L.sandbox("")
  end

  def test_load_fields
    cg("cgroup.controllers" => "cpu memory", "cpu.max" => "200000 100000") do |d|
      h = L.load_fields(root: d, version_src: "Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016")
      assert_equal %w[cgroup cpu_quota nproc sandbox], h.keys
      assert_equal "v2", h["cgroup"]
      assert_equal 2.0, h["cpu_quota"]
      assert_equal "gvisor", h["sandbox"]
    end
  end
end
