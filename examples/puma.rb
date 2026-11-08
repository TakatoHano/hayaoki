# Puma in single mode (no forked workers): one process, threads from the environment,
# bound to $PORT. Copy to config/puma.rb.
max_threads = Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
threads max_threads, max_threads

port Integer(ENV.fetch("PORT", 3000))

workers = Integer(ENV.fetch("WEB_CONCURRENCY", 0))
workers workers if workers > 0

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
