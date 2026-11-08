#!/usr/bin/env bash
# Spike 2 実行: (A) bootsnap+probe先 (B) bootsnap+probe後 (C) bootsnap無+probe先 (D) warm cache+probe先
# 各パターンを require_relative 委譲方式 orig(gem_original_require) / require の両方で実行
S=/tmp/hayaoki-spike
export GEM_HOME=$S/gems GEM_PATH=$S/gems RAILS_ENV=production
PROBE=/path/to/home/workspace/hayaoki/spike/02_probe.rb
cd $S/spike_app || exit 1
CMD='require "./config/environment"; puts "boot ok: #{Rails.application.initialized?}"'
run() { echo "== $1"; shift; env "$@" 2>&1 | grep -E "boot ok|\[probe\]|Error|error" | cut -c1-260; }
for RR in orig require; do
  echo "######## PROBE_RR=$RR"
  rm -rf tmp/cache
  run "A bootsnap+probe(-r)" PROBE_RR=$RR PROBE_LABEL=A ruby -r$PROBE -e "$CMD"
  rm -rf tmp/cache
  run "B bootsnap+probe(late)" PROBE_RR=$RR PROBE_LABEL=B PROBE_LATE=$PROBE ruby -e "$CMD"
  rm -rf tmp/cache
  run "C no bootsnap+probe(-r)" PROBE_RR=$RR PROBE_LABEL=C NO_BOOTSNAP=1 ruby -r$PROBE -e "$CMD"
  rm -rf tmp/cache
  PROBE_RR=$RR ruby -r$PROBE -e "$CMD" >/dev/null 2>&1   # cache warm-up
  run "D warm bootsnap+probe(-r)" PROBE_RR=$RR PROBE_LABEL=D PROBE_MISSING_OUT=$S/missing_D_$RR.txt ruby -r$PROBE -e "$CMD"
done
