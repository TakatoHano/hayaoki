t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep 0.03
$hayate_measured[:other] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
