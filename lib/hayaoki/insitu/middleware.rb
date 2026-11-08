# frozen_string_literal: true

require_relative "state"

module Hayaoki
  module Insitu
    # Inserted at position 0 of the Rails stack (Insitu.before_initialize). Watches the first
    # non-probe request of the process, emits the line when its body is closed, then becomes a
    # pass-through (one ivar check per request).
    class Middleware
      TOP_GROUPS = 5

      def initialize(app, state = Insitu.state)
        @app = app
        @state = state
        @ignore = state ? state.ignore_paths : []
        @done = state.nil?
      end

      def call(env)
        return @app.call(env) if @done
        if @ignore.include?(env["PATH_INFO"])
          @state.probe_hit!
          return @app.call(env)
        end
        return @app.call(env) unless claim
        first_request(env)
      end

      private

      def claim
        won = @state.claim_first_request!
        @done = true
        won
      rescue StandardError => e
        Insitu.warn_once("middleware", e)
        @done = true
        false
      end

      def first_request(env)
        snap = begin
          i18n = Insitu.i18n_loaded?
          st = @state
          st.i18n_loaded = i18n
          t0 = st.mark(:first_request_start)
          [t0, $LOADED_FEATURES.size, GC.count, Insitu.gc_time_ms]
        rescue StandardError => e
          Insitu.warn_once("middleware", e)
          nil
        end
        return @app.call(env) unless snap

        begin
          status, headers, body = @app.call(env)
        rescue Exception # record, then let the app exception go on
          finish(env, 500, snap)
          raise
        end
        if defined?(::Rack::BodyProxy)
          body = ::Rack::BodyProxy.new(body) { finish(env, status, snap) }
        else
          finish(env, status, snap)
        end
        [status, headers, body]
      end

      # Runs once (BodyProxy calls the block once). Never raises.
      def finish(env, status, snap)
        st = @state
        st.mark(:first_response_end)
        _, f0, gc0, gct0 = snap
        added = $LOADED_FEATURES.size > f0 ? $LOADED_FEATURES[f0..] : []
        gct = Insitu.gc_time_ms
        st.first_request = {
          "route" => route(env), "status" => status.to_i, "probe_hits" => st.probe_hits,
          "new_features" => added.size, "new_by_group" => groups(added),
          "gc_count" => GC.count - gc0, "gc_time_ms" => gct && gct0 ? gct - gct0 : nil,
        }
        require_relative "emitter"
        Emitter.emit(st, "ok")
      rescue StandardError => e
        Insitu.warn_once("middleware", e)
      end

      # controller#action from the router's path parameters (phase2.md §3.2: no raw path).
      def route(env)
        pp = env["action_dispatch.request.path_parameters"]
        return nil unless pp.is_a?(Hash)
        c = pp[:controller] || pp["controller"]
        a = pp[:action] || pp["action"]
        c && a ? "#{c}##{a}" : nil
      end

      def groups(paths)
        return [] if paths.empty?
        require_relative "../redact"
        specs = defined?(::Gem) && ::Gem.respond_to?(:loaded_specs) ? ::Gem.loaded_specs.values.map { |s| [s.name, s.full_gem_path] } : []
        root = defined?(::Rails) && ::Rails.respond_to?(:root) ? ::Rails.root&.to_s : nil
        root ||= Dir.pwd
        counts = Hash.new(0)
        paths.each { |p| counts[Redact.group_for(p, specs, root)] += 1 }
        counts.sort_by { |g, n| [-n, g] }.first(TOP_GROUPS)
      end
    end
  end
end
