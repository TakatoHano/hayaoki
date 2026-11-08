#!/usr/bin/env bash
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)  # リポジトリの場所
# Spike 4-3: プロトタイプ probe のオーバーヘッド (warm bootsnap / bootsnap 無し)。交互に N 回実行し中央値と p90 を比較
S=${SPIKE_DIR:-${TMPDIR:-/tmp}/hayaoki-spike}
export GEM_HOME=$S/gems GEM_PATH=$S/gems RAILS_ENV=production
P=$ROOT/spike/04_probe/probe.rb
N=${N:-15}
cd $S/spike04_app || exit 1
ruby -e 'require "./config/environment"' >/dev/null 2>&1
ruby - "$P" "$N" <<'R'
p, n = ARGV[0], ARGV[1].to_i
def t(env, *cmd) = (s = Process.clock_gettime(Process::CLOCK_MONOTONIC); system(env, *cmd, out: File::NULL, err: File::NULL) or abort("fail #{cmd}"); Process.clock_gettime(Process::CLOCK_MONOTONIC) - s)
[["bootsnap", {}], ["no-bootsnap", { "NO_BOOTSNAP" => "1" }]].each do |label, env|
  r = Hash.new { |h, k| h[k] = [] }
  n.times do
    r[:none] << t(env, "ruby", "-e", 'require "./config/environment"')
    r[:probe_out] << t(env.merge("HAYAOKI_PROBE_OUT" => "#{Dir.pwd}/../bench_out.json"), "ruby", "-r#{p}", "-e", 'require "./config/environment"')
  end
  med = ->(a) { a.sort[a.size / 2] }; p90 = ->(a) { a.sort[(a.size * 0.9).floor.clamp(0, a.size - 1)] }
  base = med[r[:none]]
  r.each { |k, a| next if a.empty?; printf("%-12s %-10s median=%.0fms p90=%.0fms (%+.1f%%)\n", label, k, med[a] * 1000, p90[a] * 1000, (med[a] / base - 1) * 100) }
end
R
