#!/usr/bin/env bash
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)  # リポジトリの場所
# Spike 4-3 エッジケース: スレッド内 require / 例外 / boot 失敗時の部分結果 / exit! / --disable-gems / fork
P=$ROOT/spike/04_probe/probe.rb
D=$ROOT/spike/04_probe/edge
O=${SPIKE_DIR:-${TMPDIR:-/tmp}/hayaoki-spike}/edge_out.json
cd $D
summ() { [ -f $O ] && ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); w=d["width"]; ev=d["events"].each_slice(w).to_a
  puts "  status=#{d["status"]} err=#{d.dig("error","class")} spans=#{ev.size}"
  ev.each { |k,n,par,s,e,m,tid| puts "   k=#{k} #{File.basename(n.to_s)} parent=#{par} dur=#{e ? ((e-s)*1000).round : "OPEN"}ms res=#{m.is_a?(String) ? File.basename(m) : m.inspect} tid=#{tid==0 ? 0 : "T"}" if n.to_s.include?("t_") }' $O || echo "  (no output)"; rm -f $O; }
echo "== thread + main concurrently"; HAYAOKI_PROBE_OUT=$O ruby -r$P -e 't = Thread.new { require "./t_slow" }; require "./t_main"; t.join'; summ
echo "== require raises (rescued)"; HAYAOKI_PROBE_OUT=$O ruby -r$P -e 'begin; require "./t_raise"; rescue => e; end; require "./t_leaf"'; summ
echo "== boot failure (uncaught)"; HAYAOKI_PROBE_OUT=$O ruby -r$P -e 'require "./t_main"; require "./t_raise"' 2>/dev/null; summ
echo "== exit!"; HAYAOKI_PROBE_OUT=$O ruby -r$P -e 'require "./t_main"; exit! 0'; summ
echo "== --disable-gems"; HAYAOKI_PROBE_OUT=$O ruby --disable-gems -r$P -e 'require "./t_main"'; summ
echo "== fork child exits normally (parent must win)"; HAYAOKI_PROBE_OUT=$O ruby -r$P -e 'require "./t_main"; Process.wait(fork { require "./t_slow" })'; summ
echo "== probe loaded twice"; HAYAOKI_PROBE_OUT=$O ruby -r$P -r$P -e 'require "./t_leaf"'; summ
