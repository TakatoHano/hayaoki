# frozen_string_literal: true

require "test_helper"

# 複数スレッドが同時に require してもスレッドごとの span が不正にならないこと
class ProbeThreadTest < Minitest::Test
  include ProbeHelper

  N = 8

  def test_concurrent_requires_keep_trees_and_ownership
    Dir.mktmpdir("hayaoki-thr") do |dir|
      N.times do |n|
        File.write("#{dir}/th#{n}_outer.rb", "sleep 0.03\nrequire './th#{n}_inner'\nsleep 0.01\n")
        File.write("#{dir}/th#{n}_inner.rb", "sleep 0.03\n")
      end
      # 2 回目は false を返す require (他スレッドの span を消してはいけない)
      File.write("#{dir}/shared.rb", "sleep 0.01\n")
      code = <<~RUBY
        q = Queue.new
        ths = #{N}.times.map do |n|
          Thread.new do
            q.pop
            require "./th\#{n}_outer"
            3.times { require "./shared"; sleep 0.005 }
            Thread.current.thread_variable_set(:n, n)
          end
        end
        #{N}.times { q << 1 }
        ths.each(&:join)
      RUBY
      r = run_probe(code, chdir: dir)
      rep = r.report
      assert_equal "ok", rep["status"]
      spans = rep.spans
      spans.each do |s|
        assert s.t1, "span #{s.name} must be closed"
        next if s.parent < 0
        p = spans.find { |x| x.idx == s.parent }
        refute_nil p, "parent index must be valid"
        assert_operator s.parent, :<, s.idx
        assert_equal p.tid, s.tid, "child must belong to the parent's thread"
        assert_operator s.t0, :>=, p.t0
        assert_operator s.t1, :<=, p.t1
      end
      tids = []
      N.times do |n|
        outer = rep.named(0, "./th#{n}_outer")
        inner = rep.named(0, "./th#{n}_inner")
        assert_equal 1, outer.size, "outer #{n}"
        assert outer[0].res.to_s.end_with?("/th#{n}_outer.rb"), "outer #{n} res: #{outer[0].res.inspect}"
        assert inner[0].res.to_s.end_with?("/th#{n}_inner.rb"), "inner #{n} res: #{inner[0].res.inspect}"
        assert_equal 1, inner.size, "inner #{n}"
        assert_equal(-1, outer[0].parent)
        assert_equal outer[0].idx, inner[0].parent
        assert_equal outer[0].tid, inner[0].tid
        refute_equal 0, outer[0].tid
        assert_operator outer[0].dur_ms, :>=, 59
        tids << outer[0].tid
      end
      assert_equal N, tids.uniq.size, "each thread has its own tid"
      assert_equal 1, rep.spans.count { |s| s.kind == 0 && s.name == "./shared" && s.res.is_a?(String) }, "shared.rb: only the first (true) require is kept"
      fc = rep["false_require"]["count"]
      assert_operator fc, :>=, 1, "false requires are counted, not kept as spans"
      assert_equal 0, spans.count { |s| s.kind <= 2 && s.res == false }
    end
  end
end
