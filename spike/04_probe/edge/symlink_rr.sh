#!/usr/bin/env bash
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)  # リポジトリの場所
# Spike 4-3: シンボリックリンク経由のディレクトリで require_relative の基準パスがネイティブと一致するか
P=$ROOT/spike/04_probe/probe.rb
D=${SPIKE_DIR:-${TMPDIR:-/tmp}/hayaoki-spike}/symt
rm -rf $D; mkdir -p $D/real/sub
echo 'puts "real target"' > $D/real/target.rb
echo 'puts "WRONG target (symlink-parent)"' > $D/target.rb
echo 'require_relative "../target"' > $D/real/sub/a.rb
ln -s $D/real/sub $D/link
cd $D; echo -n "native: "; ruby -e 'require "./link/a"'; echo -n "probe:  "; ruby -r$P -e 'require "./link/a"' 2>/dev/null
