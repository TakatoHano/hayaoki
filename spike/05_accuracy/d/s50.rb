a=Process.clock_gettime(Process::CLOCK_MONOTONIC); sleep 0.050; b=Process.clock_gettime(Process::CLOCK_MONOTONIC)
($sleeps ||= {})[50]=b-a
File.open(ENV["INNER"],"a"){_1.puts "50 #{b-a}"} if ENV["INNER"]
