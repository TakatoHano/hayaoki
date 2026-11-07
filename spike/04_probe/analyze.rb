# frozen_string_literal: true
# Spike 4-3: probe.rb の出力 JSON から木を復元し、既知の sleep (slowgem / initializer / on_load) が正しく帰属するか確認する
require "json"
d = JSON.parse(File.read(ARGV[0]))
w = d["width"]; ev = d["events"]
KINDS = %w[require require_relative load initializer on_load eager_load bundler phase]
spans = ev.each_slice(w).map { |k, n, par, s, e, m, tid| { kind: KINDS[k], name: n, parent: par, s: s, e: e, meta: m, tid: tid, children: [] } }
roots = []
spans.each_with_index { |sp, i| sp[:dur] = (sp[:e] || d["t_exit"] - d["t0"]) - sp[:s]; sp[:parent] >= 0 ? spans[sp[:parent] / w][:children] << sp : roots << sp }
spans.each { |sp| sp[:self] = sp[:dur] - sp[:children].sum { _1[:dur] } }
ms = ->(x) { (x * 1000).round(1) }
show = lambda do |sp, depth, max|
  return if depth > max
  puts "#{'  ' * depth}#{sp[:kind]} #{sp[:name].to_s.sub(%r{.*/(gems|spike04_app)/}, '')} total=#{ms[sp[:dur]]} self=#{ms[sp[:self]]} #{sp[:meta].is_a?(String) ? sp[:meta].sub(%r{.*/}, '') : ''}"
  sp[:children].each { show.(_1, depth + 1, max) }
end
puts "status=#{d['status']} spans=#{spans.size} roots=#{roots.size} probe_errors=#{d['probe_errors'].inspect} pending=#{d['pending'].inspect}"
puts "vm_start(estimated)=#{d['spawn_at'] ? ms[d['t0_real'] - d['spawn_at'].to_f] : 'n/a'}ms cpu_before_probe=#{ms[d['cpu0']]}ms"
show.(spans.find { _1[:name].to_s.end_with?("slowgem") || _1[:name] == "slowgem" }, 0, 3)
spans.select { _1[:kind] == "on_load" && _1[:meta].to_s.include?("spike04_app") }.each { show.(_1, 0, 0) }
puts "-- top-level"
roots.each { show.(_1, 0, 1) }
puts "-- kinds"
spans.group_by { _1[:kind] }.each { |k, v| puts "#{k}: #{v.size}" }
puts "-- top initializers by self"
spans.select { _1[:kind] == "initializer" }.sort_by { -_1[:self] }.first(5).each { show.(_1, 0, 0) }
puts "-- false/raised: #{spans.count { _1[:meta] == false }} / #{spans.count { _1[:meta] == 'raised' }}"
