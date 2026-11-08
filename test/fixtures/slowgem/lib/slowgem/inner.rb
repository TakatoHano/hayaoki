t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep 0.05
$hayaoki_measured[:inner] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
