# frozen_string_literal: true

# TZInfo.eager_load! のコストを測る (Rails の eager_load! initializer が production で呼ぶ)。
# 使い方: ruby tzinfo_eager_load.rb [LABEL] [RUNS]
#   HAYATE_TZ_DATA=ruby なら tzinfo-data (Ruby モジュール) を使う。それ以外は OS の zoneinfo。
# 各計測は新しいプロセスで行い、中央値を Markdown の表の行として出す。
require "rbconfig"

if ENV["HAYATE_TZ_CHILD"]
  now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0 }
  require "tzinfo"
  require "tzinfo/data" if ENV["HAYATE_TZ_DATA"] == "ruby"
  case ENV["HAYATE_TZ_CHILD"]
  when "eager"
    # Rails と同じく DataSource.get と UTC を先に済ませてから eager_load! を測る
    TZInfo::DataSource.get
    TZInfo::Timezone.get("UTC")
    t = now.()
    TZInfo.eager_load!
    puts now.() - t
  when "boot_lazy"
    # eager_load をやめた場合に起動時に残る分 (Rails の initialize_time_zone 相当)
    t = now.()
    TZInfo::DataSource.get
    TZInfo::Timezone.get("UTC")
    puts now.() - t
  when "first_zone"
    # eager_load しない場合、最初に別のゾーンを使うリクエストが払うコスト
    TZInfo::DataSource.get
    TZInfo::Timezone.get("UTC")
    t = now.()
    TZInfo::Timezone.get("Asia/Tokyo").to_local(Time.now)
    puts now.() - t
  when "info"
    ds = TZInfo::DataSource.get
    puts "#{ds.class.name.split("::").last} zones=#{ds.timezone_identifiers.size}"
  end
  exit
end

label = ARGV[0] || RUBY_PLATFORM
runs = (ARGV[1] || 7).to_i
child = lambda do |mode|
  out = IO.popen({ "HAYATE_TZ_CHILD" => mode }, [RbConfig.ruby, __FILE__], err: %i[child out], &:read)
  raise "#{mode}: #{out}" unless $?.success?
  out.strip
end
med = ->(mode) { v = Array.new(runs) { child.(mode).to_f }.sort; v[v.size / 2] }
info = child.("info")
printf("| %s | %s | %s | %.1f | %.1f | %.2f |\n", label, RUBY_VERSION, info, med.("eager"), med.("boot_lazy"), med.("first_zone"))
