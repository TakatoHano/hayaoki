a=Process.clock_gettime(Process::CLOCK_MONOTONIC); sleep 0.100; b=Process.clock_gettime(Process::CLOCK_MONOTONIC)
($sleeps ||= {})[100]=b-a
File.open(ENV["INNER"],"a"){_1.puts "100 #{b-a}"} if ENV["INNER"]
