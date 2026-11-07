a=Process.clock_gettime(Process::CLOCK_MONOTONIC); sleep 0.030; b=Process.clock_gettime(Process::CLOCK_MONOTONIC)
($sleeps ||= {})[30]=b-a
File.open(ENV["INNER"],"a"){_1.puts "30 #{b-a}"} if ENV["INNER"]
