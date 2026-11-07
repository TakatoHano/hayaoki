#!/usr/bin/env bash
# Spike 4: spike_app を複製し、既知の sleep を持つダミー gem (slowgem) と on_load フックを足した検証用アプリを作る
set -e
S=/tmp/hayaoki-spike
export GEM_HOME=$S/gems GEM_PATH=$S/gems
A=$S/spike04_app
rm -rf $A && cp -R $S/spike_app $A && rm -rf $A/tmp/cache
mkdir -p $A/vendor/slowgem/lib/slowgem
cat > $A/vendor/slowgem/slowgem.gemspec <<'G'
Gem::Specification.new { |s| s.name = "slowgem"; s.version = "0.1.0"; s.summary = "x"; s.authors = ["x"]; s.files = Dir["lib/**/*.rb"] }
G
cat > $A/vendor/slowgem/lib/slowgem.rb <<'G'
sleep 0.10                       # slowgem self time 100ms
require_relative "slowgem/inner" # 50ms (require_relative)
require "slowgem/other"          # 30ms (require)
ActiveSupport.on_load(:action_controller) { sleep 0.04 } if defined?(ActiveSupport)
G
echo 'sleep 0.05' > $A/vendor/slowgem/lib/slowgem/inner.rb
echo 'sleep 0.03' > $A/vendor/slowgem/lib/slowgem/other.rb
echo 'gem "slowgem", path: "vendor/slowgem"' >> $A/Gemfile
cat > $A/config/initializers/spike.rb <<'G'
SPIKE_INIT = 1
sleep 0.02
ActiveSupport.on_load(:active_record) { sleep 0.01 }
G
# 暗黙の名前空間 (admin.rb の無い app/models/admin/) — Zeitwerk はディレクトリパスで Kernel#require を呼ぶ
mkdir -p $A/app/models/admin
echo 'class Admin::Thing; end' > $A/app/models/admin/thing.rb
cd $A && bundle install --local --quiet && echo "app ready: $A"
