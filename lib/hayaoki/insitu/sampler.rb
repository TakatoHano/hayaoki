# frozen_string_literal: true

require_relative "clock"
require_relative "proc"

module Hayaoki
  module Insitu
    # Opt-in (HAYAOKI_INSITU_SAMPLER=1, Linux): a forked child reads the state of the parent's main
    # thread (field 3 of /proc/<pid>/task/<pid>/stat) every INTERVAL_MS from load until the end of
    # initialize! and reports how long the thread was runnable (R), in uninterruptible sleep (D:
    # file IO, page faults) or in interruptible sleep (S: network, sleep, waiting for another thread),
    # and for how long the child itself did not run (gaps). Design: resource-hints.md §2.2.3.
    #
    # A child process, not a Ruby thread: a thread needs the GVL, and the main thread keeps it while
    # it is blocked in a page fault or in the stat/open/dlopen calls of require, so a thread would
    # miss the very time this is meant to measure.
    #
    # The parent never writes to the child. Closing the control pipe (on purpose, or because the
    # parent exited or exec'd) ends the child, which then tries to write one line to the result pipe.
    module Sampler
      INTERVAL_MS = 10
      # A step between two samples longer than GAP_FACTOR x INTERVAL_MS is a gap: the child did not run
      GAP_FACTOR = 5
      # The child stops on its own after this long, writes its result and exits
      MAX_MS = 120_000
      # Longest the parent waits for the result line (normally well under 1 ms)
      COLLECT_TIMEOUT_S = 0.1
      REAP_TRIES = 20 # x 1 ms
      STAT_READ = 512
      WIRE_TAG = "hs1"
      WIRE_KEYS = %w[samples wall r d s other gaps gap gap_max trunc suspend cpu runq majflt].freeze

      R = "R".ord
      S = "S".ord
      D = "D".ord
      GONE_STATES = ["Z".ord, "X".ord, "x".ord].freeze

      # Adds up the time between samples by the state seen at the later sample. All values in ms.
      # r + d + s + other + gap == wall (last sample - first sample).
      class Tally
        attr_reader :samples, :r, :d, :s, :other, :gaps, :gap, :gap_max

        def initialize(interval_ms: INTERVAL_MS, gap_factor: GAP_FACTOR)
          @interval = interval_ms.to_f
          @gap_over = @interval * gap_factor
          @samples = 0
          @r = @d = @s = @other = @gap = @gap_max = 0.0
          @gaps = 0
          @first = @last = nil
        end

        # `state`: the state byte ("R".ord, ...) or nil when the read failed
        def add(now_ms, state)
          @samples += 1
          if @last.nil?
            @first = @last = now_ms
            return
          end
          step = now_ms - @last
          step = 0.0 if step.negative?
          @last = now_ms
          if step > @gap_over
            late = step - @interval
            @gaps += 1
            @gap += late
            @gap_max = late if late > @gap_max
            step = @interval
          end
          case state
          when R then @r += step
          when D then @d += step
          when S then @s += step
          else @other += step
          end
        end

        def wall = @first ? @last - @first : 0.0
      end

      # What the parent keeps: the child's pid and the two pipe ends. `result` is safe to call any
      # number of times and from a forked copy (which gets nil and leaves the child alone).
      class Handle
        attr_reader :pid

        def self.failed(status) = new(nil, nil, nil, result: { "status" => status })

        def initialize(pid, ctl, res, interval_ms: INTERVAL_MS, fork_us: nil, result: nil, timeout: COLLECT_TIMEOUT_S)
          @pid = pid
          @ctl = ctl
          @res = res
          @interval_ms = interval_ms
          @fork_us = fork_us
          @result = result
          @timeout = timeout
          @owner = Process.pid
          @reaped = pid.nil?
        end

        def running? = @result.nil? && @owner == Process.pid

        # Ends the child and returns the "sampler" object of the line. `till` names the point that
        # ended the window ("initialize_end" or "emit"). The first call decides; later calls return
        # the same hash. Never raises.
        def result(till = "emit")
          return @result if @result
          return nil unless @owner == Process.pid
          t0 = Sampler.mono_us
          text = finish(read: true)
          wire = Sampler.decode(text)
          @result = wire ? Sampler.fields(wire, till: till, interval_ms: @interval_ms, fork_us: @fork_us, collect_us: Sampler.mono_us - t0) : { "status" => text.nil? ? "timeout" : "no_result" }
        rescue StandardError
          @result ||= { "status" => "error" }
        end

        # Ends the child without reading its result (the parent is about to fork, or is exiting).
        # After a result this only retries the reap when the first try did not get the child.
        def abort(status = "aborted")
          return unless @owner == Process.pid
          if @result
            reap(false) unless @reaped
            return
          end
          @result = { "status" => status }
          finish(read: false)
          nil
        rescue StandardError
          nil
        end

        private

        # Closing the control pipe is the stop signal. => the text read ("" when the child wrote
        # nothing), or nil when the child did not answer in time.
        def finish(read:)
          close(@res) unless read # the child's write then fails and it exits
          close(@ctl)
          text = read ? read_result : ""
          close(@res)
          reap(text.nil?)
          text
        end

        # Reads until EOF (the child closes its end by exiting) or the timeout
        def read_result
          text = +""
          deadline = Sampler.mono_us + @timeout * 1_000_000
          loop do
            left = (deadline - Sampler.mono_us) / 1_000_000.0
            return nil if left <= 0 || !IO.select([@res], nil, nil, left)
            chunk = @res.read_nonblock(4096, exception: false)
            return text if chunk.nil?
            text << chunk unless chunk == :wait_readable
          end
        end

        # Never blocks for more than about REAP_TRIES ms. Process::Status.wait leaves $? alone.
        def reap(kill)
          Process.kill("KILL", @pid) if kill
          REAP_TRIES.times do
            return @reaped = true if waited?
            sleep 0.001
          end
          Process.kill("KILL", @pid) unless kill
          @reaped = waited?
        rescue SystemCallError
          @reaped = true # ECHILD / ESRCH: already gone, or reaped by someone else
        end

        def waited?
          st = Process::Status.wait(@pid, Process::WNOHANG)
          !st.nil? && st.pid != 0
        end

        def close(io)
          io.close if io && !io.closed?
        rescue IOError, SystemCallError
          nil
        end
      end

      class << self
        # Forks the sampler child for the main thread of `pid`. Returns a Handle (also when the
        # sampler could not start: its result then only carries a "status"). Never raises.
        # `stat_path` and `threads` are injectable for tests.
        def start(pid: Process.pid, stat_path: nil, interval_ms: INTERVAL_MS, max_ms: MAX_MS, threads: Thread.list.size,
                  timeout: COLLECT_TIMEOUT_S)
          # fork copies only the calling thread; with other threads alive the copy can hold their locks
          return Handle.failed("threads") if threads > 1
          ios = []
          keep = []
          begin
            ios << (stat = File.open(stat_path || "/proc/#{pid}/task/#{pid}/stat"))
          rescue SystemCallError, IOError
            return Handle.failed("unsupported")
          end
          # One read in the parent: checks the file is usable and touches the code the child will run
          return Handle.failed("unsupported") unless read_state(stat, +"").is_a?(Integer)
          ios.concat(ctl = IO.pipe).concat(res = IO.pipe)
          t0 = mono_us
          Insitu.sampler_fork = true
          child = Process.fork
          if child.nil?
            ctl[1].close
            res[0].close
            child_main(ctl[0], res[1], stat, interval_ms: interval_ms, max_ms: max_ms) # ends in exit!
          end
          keep = [ctl[1], res[0]]
          Handle.new(child, *keep, interval_ms: interval_ms, fork_us: mono_us - t0, timeout: timeout)
        rescue StandardError, NotImplementedError
          Handle.failed("fork_failed")
        ensure
          # parent only: the child leaves through exit!, which skips this
          Insitu.sampler_fork = false
          (ios.to_a - keep.to_a).each { |io| io.close unless io.closed? }
        end

        # State byte of a stat line read from offset 0 of `io` into `buf`; :gone when the thread no
        # longer exists (parent exited: ESRCH, or zombie); nil when the read or the line is unusable.
        # comm may contain ")" so the state is the byte two past the last ")".
        def read_state(io, buf)
          io.pread(STAT_READ, 0, buf)
          i = buf.rindex(")") or return nil
          b = buf.getbyte(i + 2) or return nil
          GONE_STATES.include?(b) ? :gone : b
        rescue Errno::ESRCH, Errno::ENOENT
          :gone
        rescue SystemCallError, IOError
          nil
        end

        # The sampling loop, without any IO of its own. `wait` sleeps one interval and returns :stop
        # when the parent closed the control pipe, else :tick. => [report?, truncated?]
        def run_loop(tally, clock:, read_state:, wait:, max_ms: MAX_MS)
          t0 = clock.call
          st = read_state.call
          return [false, false] if st == :gone
          tally.add(t0, st)
          loop do
            cmd = wait.call
            t = clock.call
            st = read_state.call
            return [cmd == :stop, false] if st == :gone
            tally.add(t, st)
            return [true, false] if cmd == :stop
            return [true, true] if t - t0 >= max_ms
          end
        end

        # One line: the tag, then WIRE_KEYS in order; durations as integer µs, "-" for unknown
        def encode(values)
          "#{WIRE_TAG} #{WIRE_KEYS.map { |k| values[k].nil? ? "-" : values[k].round }.join(" ")}\n"
        end

        # => {"samples" => Integer, ...} or nil when the text is not a complete result line
        def decode(text)
          f = text.to_s.split
          return nil unless f.shift == WIRE_TAG && f.size == WIRE_KEYS.size
          WIRE_KEYS.zip(f).to_h { |k, v| [k, v == "-" ? nil : Integer(v, 10)] }
        rescue ArgumentError
          nil
        end

        # The "sampler" object of the line, from a decoded result
        def fields(wire, till:, interval_ms:, fork_us:, collect_us:)
          ms = ->(k) { wire[k] && (wire[k] / 1000.0).round }
          { "status" => "ok", "until" => till, "interval_ms" => interval_ms, "wall_ms" => ms["wall"], "samples" => wire["samples"],
            "r_ms" => ms["r"], "d_ms" => ms["d"], "s_ms" => ms["s"], "other_ms" => ms["other"],
            "gaps" => wire["gaps"], "gap_ms" => ms["gap"], "gap_max_ms" => ms["gap_max"],
            "truncated" => wire["trunc"] == 1, "suspend_ms" => ms["suspend"],
            "sampler_cpu_ms" => ms["cpu"], "sampler_runq_wait_ms" => ms["runq"], "sampler_majflt" => wire["majflt"],
            "fork_us" => fork_us&.round, "collect_us" => collect_us&.round }
        end

        def mono_us = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_microsecond)

        private

        # Runs in the forked child and always ends in exit!, so no at_exit handler of the app runs
        # and nothing buffered is flushed twice. Writes only to the result pipe.
        def child_main(ctl, res, stat, interval_ms:, max_ms:)
          %w[TERM INT HUP QUIT].each { |s| Signal.trap(s, "SYSTEM_DEFAULT") }
          Signal.trap("PIPE", "IGNORE")
          # no GC: marking would copy every page shared with the parent; the loop allocates little
          GC.disable
          [[$stdin, "r"], [$stdout, "w"], [$stderr, "w"]].each { |io, mode| io.reopen(File::NULL, mode) }
          Process.setproctitle("hayaoki sampler")
          own = own_counters
          mono = mono_us
          tally = Tally.new(interval_ms: interval_ms)
          buf = +""
          rd = [ctl]
          interval_s = interval_ms / 1000.0
          t0 = Clock.now_ms
          report, truncated = run_loop(
            tally, max_ms: max_ms, clock: -> { Clock.now_ms }, read_state: -> { read_state(stat, buf) },
            wait: -> { IO.select(rd, nil, nil, interval_s) ? :stop : :tick }
          )
          res.write(encode(wire(tally, truncated, own, own_counters, Clock.now_ms - t0, mono_us - mono))) if report
        rescue Exception # rubocop:disable Lint/RescueException -- nothing may leave the child
          nil
        ensure
          exit!(0)
        end

        # The child's own CPU ms, run-queue wait ms and major faults (the last two nil off Linux)
        def own_counters = [Clock.cpu_ms, ProcFS.runq_wait_ms, ProcFS.majflt]

        def wire(tally, truncated, own0, own1, boot_ms, mono_us)
          us = ->(v) { v && v * 1000.0 }
          d = ->(i) { own0[i] && own1[i] ? own1[i] - own0[i] : nil }
          { "samples" => tally.samples, "wall" => us[tally.wall], "r" => us[tally.r], "d" => us[tally.d], "s" => us[tally.s],
            "other" => us[tally.other], "gaps" => tally.gaps, "gap" => us[tally.gap], "gap_max" => us[tally.gap_max],
            "trunc" => truncated ? 1 : 0,
            # CLOCK_BOOTTIME counts a suspended system, CLOCK_MONOTONIC does not
            "suspend" => Clock.boottime? ? [boot_ms * 1000.0 - mono_us, 0.0].max : nil,
            "cpu" => us[d[0]], "runq" => us[d[1]], "majflt" => d[2] }
        end
      end
    end
  end
end
