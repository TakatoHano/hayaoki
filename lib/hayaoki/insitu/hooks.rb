# frozen_string_literal: true

require_relative "clock"
require_relative "state"

module Hayaoki
  module Insitu
    # Coarse phase hooks (phase2.md §1.1 P4/P5/P5e). Ported from the probe's patterns, not shared:
    # insitu only stamps start/end on Insitu.state. No Kernel hooks, no per-require work.
    # Prepends in total: Bundler::Runtime, Rails::Application, Zeitwerk::Loader, and one per
    # eager_load_namespaces member (only when config.eager_load is on).
    module Hooks
      module BundlerHook
        def require(*groups)
          st = Hayaoki::Insitu.state
          first = st && !st.marks.key?(:bundler_require_start)
          if first
            st.mark(:bundler_require_start)
            Hayaoki::Insitu.install_rails_hooks
          end
          super
        ensure
          st.mark(:bundler_require_end) if first
        end
      end

      module AppHook
        def initialize!(...)
          Hayaoki::Insitu.before_initialize(self)
          begin
            r = super
          rescue Exception => e # recorded, then re-raised
            Hayaoki::Insitu.boot_error(e)
            raise
          end
          Hayaoki::Insitu.after_initialize
          r
        end
      end

      # Process._fork (Ruby >= 3.1) is called by fork, Process.fork and Kernel#fork in both
      # parent and child. Parent: remember that it has children. Child: stamp the fork time.
      module ForkHook
        def _fork
          return super if Hayaoki::Insitu.sampler_fork
          st = Hayaoki::Insitu.state
          # before the fork, so no child inherits the sampler's pipes; a forked worker has no sampler data
          st&.sampler&.abort("forked")
          pid = super
          if st
            pid.zero? ? st.forked_in_child! : st.forked_parent!
          end
          pid
        end
      end

      module LoaderEagerLoadHook
        def eager_load(...)
          st = Hayaoki::Insitu.state
          st ? st.eager_span(self) { super } : super
        end
      end

      # Finisher's eager_load! calls config.eager_load_namespaces.each(&:eager_load!) and Rails.eager_load!.
      # TZInfo / I18n style eager loads do no require, so only this hook sees them.
      module NamespaceEagerLoadHook
        def eager_load!(...)
          st = Hayaoki::Insitu.state
          st ? st.eager_span(self) { super } : super
        end
      end
    end

    @rails_hooked = false
    @middleware_inserted = false

    class << self
      def start!(env: ENV, load_ms: Clock.now_ms)
        @program = program_name
        @state = State.new(env: env, entry: detect_entry, load_ms: load_ms, bootsnap_cache: bootsnap_cache_before_setup(env))
        start_sampler(env)
        ::Bundler::Runtime.prepend(Hooks::BundlerHook) if defined?(::Bundler::Runtime)
        install_rails_hooks if defined?(::Rails::Application)
        ::Process.singleton_class.prepend(Hooks::ForkHook) if ::Process.respond_to?(:_fork)
        at_exit { at_exit! }
      rescue StandardError => e
        warn_once("start", e)
      end

      # Opt-in and Linux only (resource-hints.md §2.2.3). The file is not even loaded otherwise.
      def start_sampler(env, linux: RUBY_PLATFORM.include?("linux"))
        return unless linux && sampler_enabled?(env)
        require_relative "sampler"
        # Loaded by Bundler.require or later, other gems' fork hooks (APM, ForkTracker) would run in the child
        @state.sampler = @state.entry == "boot_rb" ? Sampler.start : Sampler::Handle.failed("late_load")
      rescue StandardError, LoadError => e
        warn_once("sampler", e)
      end

      # "boot_rb": loaded before Bundler.require (the intended place). "bundler": loaded by
      # Bundler.require (gem "hayaoki", require: "hayaoki/insitu"), so P4 start is unknown.
      def detect_entry
        return "bundler" if caller_locations.any? { |l| l.path.to_s.end_with?("/bundler/runtime.rb") }
        defined?(::Rails::Application) ? "other" : "boot_rb"
      end

      # Whether the bootsnap cache dir existed before bootsnap/setup ran (warm image vs cold).
      # nil when bootsnap is already loaded (we cannot tell any more).
      def bootsnap_cache_before_setup(env)
        return nil if defined?(::Bootsnap)
        dir = env["BOOTSNAP_CACHE_DIR"]
        if dir.nil? || dir.empty?
          gemfile = env["BUNDLE_GEMFILE"]
          root = gemfile && !gemfile.empty? ? File.dirname(gemfile) : Dir.pwd
          dir = File.join(root, "tmp", "cache")
        end
        Dir.exist?(File.join(dir, "bootsnap"))
      rescue StandardError
        nil
      end

      def install_rails_hooks
        return if @rails_hooked
        @rails_hooked = true
        ::Rails::Application.prepend(Hooks::AppHook)
      rescue StandardError => e
        warn_once("rails hooks", e)
      end

      def before_initialize(app)
        st = @state or return
        st.mark(:initialize_start)
        # Snapshot here: `rails db:prepare` runs its tasks inside Rake.with_application, which
        # restores an empty Rake.application before at_exit, so a later check would say "server".
        st.server = server_process? if st.server.nil?
        unless @middleware_inserted || st.emit_mode == "ready"
          require_relative "middleware"
          # Recorded on the config proxy; Rails applies it when it builds the stack (Finisher).
          app.config.middleware.insert_before(0, Middleware)
          @middleware_inserted = true
        end
        install_eager_hooks(app) if app.config.eager_load
      rescue StandardError => e
        warn_once("initialize", e)
      end

      def install_eager_hooks(app)
        ::Zeitwerk::Loader.prepend(Hooks::LoaderEagerLoadHook) if defined?(::Zeitwerk::Loader)
        list = app.config.eager_load_namespaces.to_a
        list << ::Rails
        list.uniq.each do |ns|
          next unless ns.respond_to?(:eager_load!)
          sc = ns.singleton_class
          sc.prepend(Hooks::NamespaceEagerLoadHook) unless sc.include?(Hooks::NamespaceEagerLoadHook)
        end
      end

      def after_initialize
        st = @state or return
        st.mark(:initialize_end)
        # boot is over: the main thread only sleeps from here on, so the sampler's window ends
        st.sampler&.result("initialize_end")
        return unless st.emit_mode == "ready"
        return unless st.server != false && server_process?
        st.i18n_loaded = i18n_loaded?
        require_relative "emitter"
        Emitter.emit(st, "ok")
      rescue StandardError => e
        warn_once("initialize", e)
      end

      # Job runners started by their own executable. Matched on the first word of $0 at load
      # (Sidekiq later rewrites $0 to "sidekiq 7.x app [0 of 5 busy]"; bin/jobs is Solid Queue).
      NON_SERVER_PROGRAMS = %w[sidekiq jobs good_job solid_queue sidekiqswarm].freeze

      def program_name
        File.basename($PROGRAM_NAME.to_s.split.first.to_s)
      rescue StandardError
        nil
      end

      # false for rake (also `rails db:migrate`, which runs through Rake), `rails console`,
      # `rails runner` and the job runners above. Anything else (puma, rackup, a Lambda adapter,
      # custom scripts) counts as a server.
      def server_process?
        return false if NON_SERVER_PROGRAMS.include?(@program || program_name)
        return false if defined?(::Rake) && ::Rake.respond_to?(:application) && !::Rake.application.top_level_tasks.empty?
        # `bin/rails <task>` falls back to RakeCommand (loaded only then); `rails server` loads ServerCommand.
        return false if defined?(::Rails::Command::RakeCommand) && !defined?(::Rails::Command::ServerCommand)
        return false if defined?(::Rails::Console)
        return false if defined?(::Rails::Command::RunnerCommand) && !defined?(::Rails::Command::ServerCommand)
        true
      rescue StandardError
        true
      end

      def boot_error(error)
        @state&.boot_error = error.class.name
      rescue StandardError
        nil
      end

      # Fallback line at exit. "incomplete": this process started its first request but the
      # response never finished (written even by a forking parent or a non-server). "boot_error"
      # is always written. "no_request" only from a server process that did not fork children
      # (Puma cluster master: the workers write their own) and not from rake, console, runner or
      # a job runner (State#server, snapshotted at initialize!, or the check at exit).
      def at_exit!
        st = @state or return
        return if st.emitted?
        status =
          if st.boot_error then "boot_error"
          elsif st.first_request_incomplete? then "incomplete"
          elsif st.forked_children? || st.server == false || !server_process? then return
          else "no_request"
          end
        require_relative "emitter"
        Emitter.emit(st, status)
      rescue StandardError => e
        warn_once("at_exit", e)
      ensure
        # no line was written (rake, console, a master with workers): still end and reap the child
        st&.sampler&.abort
      end
    end
  end
end
