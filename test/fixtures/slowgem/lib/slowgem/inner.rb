t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep 0.05
$hayate_measured[:inner] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
