# frozen_string_literal: true
N = 15; WARM = 2
PROBE = File.expand_path("03_probe.rb", __dir__)
base = ["ruby"]
conds = {
  a: [{}, base + ["-e", 'require "rails/all"']],
  b: [{}, base + ["-r", PROBE, "-e", 'require "rails/all"']],
  c: [{ "HAYAOKI_PROBE_MODE" => "hook" }, base + ["-r", PROBE, "-e", 'require "rails/all"']],
}
t = Hash.new { |h, k| h[k] = [] }
(N + WARM).times do |i|
  conds.each do |k, (env, cmd)|
    s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pid = Process.spawn(env, *cmd, out: File::NULL, err: File::NULL)
    Process.wait(pid)
    e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    t[k] << (e - s) * 1000 if i >= WARM
  end
end
cnt = "#{ENV['TMPDIR'] || '/tmp'}/hayaoki_count"
system({ "HAYAOKI_COUNT_FILE" => cnt }, *conds[:b][1], out: File::NULL, err: File::NULL)
pct = ->(a, p) { s = a.sort; s[((s.size - 1) * p).ceil] }
med = ->(a) { s = a.sort; s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2 }
t.each { |k, v| puts format("%s median=%.1fms p90=%.1fms", k, med[v], pct[v, 0.9]) }
a = med[t[:a]]
puts format("b overhead=%.2f%%  c overhead=%.2f%%", (med[t[:b]] - a) / a * 100, (med[t[:c]] - a) / a * 100)
puts "p90 basis: b=%.2f%% c=%.2f%%" % [(pct[t[:b], 0.9] - pct[t[:a], 0.9]) / pct[t[:a], 0.9] * 100, (pct[t[:c], 0.9] - pct[t[:a], 0.9]) / pct[t[:a], 0.9] * 100]
puts "require count=#{File.read(cnt) rescue '?'}"
