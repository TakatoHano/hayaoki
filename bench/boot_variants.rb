# frozen_string_literal: true

# 起動時の設定を変えた版 (variant) ごとに、Rails アプリの起動時間と「最初に使うときのコスト」を測る。
# アプリのディレクトリで実行する: ruby boot_variants.rb [RUNS] [VARIANT...]
# variant ごとに config/initializers/zz_hayate_variant.rb を書き、終わったら消す。
# 各計測は新しいプロセスで行い、中央値を Markdown の表として出す。
require "json"
require "rbconfig"

VARIANTS = {
  "base" => "",
  "tzinfo_lazy" => "Rails.application.config.eager_load_namespaces.delete(TZInfo)",
  "i18n_lazy" => "Rails.application.config.eager_load_namespaces.delete(I18n)",
  "i18n_en_only" => "Rails.application.config.i18n.available_locales = [:en]",
  "controllers_lazy" => "Rails.application.config.eager_load_namespaces.delete(AbstractController)",
  "devise_no_reload" => "Devise.reload_routes = false if defined?(Devise)",
  "all" => <<~RUBY,
    Rails.application.config.eager_load_namespaces.delete(TZInfo)
    Rails.application.config.eager_load_namespaces.delete(AbstractController)
    Devise.reload_routes = false if defined?(Devise)
  RUBY
}.freeze
FILE = "config/initializers/zz_hayate_variant.rb"

CHILD = <<~'RUBY'
  now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0 }
  t = now.()
  require "./config/environment"
  r = { "boot" => now.() - t }
  # tzinfo-data のゾーン定義が起動時にいくつ読み込まれたか (zoneinfo の場合は 0)
  r["tz_defs"] = $LOADED_FEATURES.count { _1.include?("/tzinfo/data/definitions/") }
  # 最初のリクエストが払うコストの代わりに、よく使う処理を 1 回ずつ測る
  t = now.(); s = I18n.t("errors.messages.blank", locale: :en); r["first_t_en"] = now.() - t
  r["t_ok"] = !s.to_s.include?("translation missing")
  t = now.(); Time.find_zone!("Asia/Tokyo").now; r["first_zone"] = now.() - t
  t = now.()
  ctrls = AbstractController::Base.descendants.reject(&:abstract?)
  ctrls.each(&:action_methods)
  r["all_action_methods"] = now.() - t
  r["controllers"] = ctrls.size
  t = now.(); n = Rails.application.routes.routes.size; r["routes_access"] = now.() - t
  r["routes"] = n
  r["devise_mappings"] = defined?(Devise) ? Devise.mappings.size : nil
  r["eager_load_namespaces"] = Rails.application.config.eager_load_namespaces.map(&:to_s).sort.join(",")
  puts JSON.generate(r)
RUBY

runs = (ARGV[0] || 5).to_i
names = ARGV[1..].to_a.empty? ? VARIANTS.keys : ARGV[1..]
med = ->(a) { s = a.compact.sort; s.empty? ? nil : s[s.size / 2] }
fmt = ->(x) { x.nil? ? "-" : (x.is_a?(Float) ? format("%.1f", x) : x.to_s) }

rows = names.map do |name|
  File.write(FILE, "# hayate bench variant: #{name}\n#{VARIANTS.fetch(name)}\n")
  samples = Array.new(runs + 1) do
    out = IO.popen([RbConfig.ruby, "-e", CHILD], err: %i[child out], &:read)
    raise "#{name}: #{out[-2000..] || out}" unless $?.success?
    JSON.parse(out.lines.last)
  end.drop(1) # 1 回目は bootsnap などのウォームアップ
  keys = %w[boot first_t_en first_zone all_action_methods routes_access]
  row = { "variant" => name }
  keys.each { |k| row[k] = med.(samples.map { _1[k] }) }
  last = samples.last
  %w[t_ok controllers routes devise_mappings tz_defs].each { |k| row[k] = last[k] }
  row
ensure
  File.delete(FILE) if File.exist?(FILE)
end

base = rows.find { _1["variant"] == "base" }&.fetch("boot")
puts "| variant | boot ms | vs base | first t(:en) | first zone | all action_methods | routes access | t ok | controllers | routes | devise mappings | tz defs loaded |"
puts "|---|---|---|---|---|---|---|---|---|---|---|---|"
rows.each do |r|
  diff = base && r["boot"] ? format("%+.1f", r["boot"] - base) : "-"
  puts "| #{r["variant"]} | #{fmt.(r["boot"])} | #{diff} | #{fmt.(r["first_t_en"])} | #{fmt.(r["first_zone"])} | " \
       "#{fmt.(r["all_action_methods"])} | #{fmt.(r["routes_access"])} | #{r["t_ok"]} | #{r["controllers"]} | #{r["routes"]} | #{fmt.(r["devise_mappings"])} | #{r["tz_defs"]} |"
end
