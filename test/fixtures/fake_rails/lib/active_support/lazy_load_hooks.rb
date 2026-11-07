# ActiveSupport::LazyLoadHooks の最小の模造 (シグネチャは Rails 7.0〜8.1 と同じ)
module ActiveSupport
  module LazyLoadHooks
    def self.extended(base)
      base.instance_variable_set(:@load_hooks, Hash.new { |h, k| h[k] = [] })
      base.instance_variable_set(:@loaded, Hash.new { |h, k| h[k] = [] })
    end

    def on_load(name, options = {}, &block)
      @loaded[name].each { |base| execute_hook(name, base, options, block) }
      @load_hooks[name] << [block, options]
    end

    def run_load_hooks(name, base = Object)
      @loaded[name] << base
      @load_hooks[name].each { |hook, options| execute_hook(name, base, options, hook) }
    end

    private

    def execute_hook(name, base, options, block)
      base.instance_eval(&block)
    end
  end

  extend LazyLoadHooks
end
