# 既知の sleep を持つダミー gem。各 sleep の実測値を $hayaoki_measured に残す (テストは実測値を基準にする)
$hayaoki_measured ||= {}
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep 0.10
$hayaoki_measured[:slowgem] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
require_relative "slowgem/inner"
require "slowgem/other"
ActiveSupport.on_load(:action_controller) do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  sleep 0.04
  $hayaoki_measured[:on_load] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
end
