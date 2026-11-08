#!/usr/bin/env bash
# リポジトリを public にした後に実行する (Free プランの private リポジトリでは rulesets を使えない)。
# 同名の ruleset があれば更新し、無ければ作成する。
set -euo pipefail
repo="${1:-TakatoHano/hayaoki}"
dir="$(cd "$(dirname "$0")" && pwd)"
for f in "$dir"/*.json; do
  name="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["name"]' "$f")"
  id="$(gh api "repos/$repo/rulesets" -q ".[] | select(.name == \"$name\") | .id")"
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input "$f" -q '"updated: \(.name) (\(.id))"'
  else
    gh api -X POST "repos/$repo/rulesets" --input "$f" -q '"created: \(.name) (\(.id))"'
  fi
done
