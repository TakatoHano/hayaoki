#!/usr/bin/env bash
# Generates the minimal Rails app the same way .github/workflows/templates.yml does, but with
# hayaoki 0.4.4 from rubygems instead of a vendored copy. Usage: gen_minimal.sh OUTDIR
set -euo pipefail
OUT="${1:?usage: gen_minimal.sh OUTDIR}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RAILS_VERSION="${RAILS_VERSION:-8.0.2}"
HAYAOKI_VERSION="${HAYAOKI_VERSION:-0.4.4}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

script='
set -euo pipefail
cd /work
gem install --no-document rails -v "$RAILS_VERSION" >/dev/null
rails "_${RAILS_VERSION}_" new app --minimal --skip-git --skip-docker --skip-bundle --skip-kamal --skip-thruster --skip-solid >/dev/null
cd app
cat >> Gemfile <<GEMS
gem "bootsnap", require: false
gem "hayaoki", "$HAYAOKI_VERSION", require: false
GEMS
cat > config/boot.rb <<BOOT
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "hayaoki/insitu"
require "bootsnap/setup"
BOOT
cat > app/controllers/home_controller.rb <<CTRL
class HomeController < ApplicationController
  def index
    render plain: "ok"
  end
end
CTRL
cat > config/routes.rb <<ROUTES
Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  root "home#index"
end
ROUTES
rm -f config/master.key
bundle install >/dev/null
bundle lock --add-platform x86_64-linux >/dev/null
'
export RAILS_VERSION HAYAOKI_VERSION
if command -v gem >/dev/null && gem list -i rails -v "$RAILS_VERSION" >/dev/null 2>&1; then
  mkdir -p "$OUT/.gen" && ( sed 's#cd /work#cd "$GEN"#' <<<"$script" > "$OUT/.gen.sh"; GEN="$OUT/.gen" bash "$OUT/.gen.sh" ); rm -f "$OUT/.gen.sh"
  mv "$OUT/.gen/app"/* "$OUT/.gen/app"/.[!.]* "$OUT/" 2>/dev/null || true; rm -rf "$OUT/.gen"
else
  docker run --rm -e RAILS_VERSION -e HAYAOKI_VERSION -v "$OUT:/work" docker.io/library/ruby:3.4.7-slim \
    bash -c "apt-get update -qq && apt-get install -y -qq build-essential git libyaml-dev pkg-config >/dev/null && $script"
  mv "$OUT/app"/* "$OUT/app"/.[!.]* "$OUT/" 2>/dev/null || true; rmdir "$OUT/app"
fi
cp "$ROOT/examples/puma.rb" "$OUT/config/puma.rb"
printf '%s\n' .git .gitignore '/log/*' '/tmp/*' '!/log/.keep' '!/tmp/.keep' /config/master.key '.env*' > "$OUT/.dockerignore"
