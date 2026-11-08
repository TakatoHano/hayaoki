#!/usr/bin/env bash
# Spike 4-2 実行: 各方式で boot の成否、ラッパー呼出回数、bundled_gems 警告の保持、boot 時間 (warm bootsnap) を比較
S=/tmp/hayaoki-spike
export GEM_HOME=$S/gems GEM_PATH=$S/gems RAILS_ENV=production
P=/path/to/home/workspace/hayaoki/spike/04_alias/probe_variants.rb
cd $S/spike04_app || exit 1
CMD='require "./config/environment"; $stderr.puts "boot ok"; begin; Kernel.require "fiddle"; rescue LoadError; end'
for v in none naive bindcall callee chain runtime; do
  echo "== $v"
  R=$([ $v = none ] && echo "" || echo "-r$P")
  ruby $R -e "$CMD" >/dev/null 2>&1   # bootsnap cache warm-up
  HAYAOKI_V=$v HAYAOKI_TP=1 ruby $R -e "$CMD" 2>&1 | grep -E "boot ok|^\[|Error|fiddle used" | cut -c1-230
  t0=$(ruby -e 'p Process.clock_gettime(Process::CLOCK_MONOTONIC)')
  for i in 1 2 3 4 5; do HAYAOKI_V=$v ruby $R -e 'require "./config/environment"' >/dev/null 2>&1; done
  ruby -e "printf(\"  avg boot %.0fms\n\", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - $t0) * 200)"
done
