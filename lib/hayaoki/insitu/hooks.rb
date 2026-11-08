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
          pid = super
          st = Hayaoki::Insitu.state
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
        @state = State.new(env: env, entry: detect_entry, load_ms: load_ms, bootsnap_cache: bootsnap_cache_before_setup(env))
        ::Bundler::Runtime.prepend(Hooks::BundlerHook) if defined?(::Bundler::Runtime)
        install_rails_hooks if defined?(::Rails::Application)
        ::Process.singleton_class.prepend(Hooks::ForkHook) if ::Process.respond_to?(:_fork)
        at_exit { at_exit! }
      rescue StandardError => e
        warn_once("start", e)
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
        return unless st.emit_mode == "ready"
        st.i18n_loaded = i18n_loaded?
        require_relative "emitter"
        Emitter.emit(st, "ok")
      rescue StandardError => e
        warn_once("initialize", e)
      end

      # false for rake (also `rails db:migrate`, which runs through Rake), `rails console` and
      # `rails runner`. Anything else (puma, rackup, a Lambda adapter, custom scripts) counts as a server.
      def server_process?
        return false if defined?(::Rake) && ::Rake.respond_to?(:application) && !::Rake.application.top_level_tasks.empty?
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

      # Fallback line for a server process that got no request (or failed to boot). No
      # "no_request" line from a process that forked children (Puma cluster master, the
      # workers write their own) or from a non-server command (rake, console, runner).
      def at_exit!
        st = @state or return
        return if st.emitted?
        return if !st.boot_error && (st.forked_children? || !server_process?)
        require_relative "emitter"
        Emitter.emit(st, st.boot_error ? "boot_error" : "no_request")
      rescue StandardError => e
        warn_once("at_exit", e)
      end
    end
  end
end
