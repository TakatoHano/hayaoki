# frozen_string_literal: true
# Spike 4-3: 設計書 docs/design/probe.md のプロトタイプ。alias chain 方式の require フック + 遅延インストール +
# フラット配列記録 + 自前 JSON 書き出し。`ruby -r ./probe.rb -e 'require "./config/environment"'`
# 出力先: ENV["HAYATE_PROBE_OUT"] (未設定なら stderr に件数だけ出す)
unless defined?(::Hayate::Probe)
module Hayate; end
module Hayate::Probe
  CLOCK = Process::CLOCK_MONOTONIC
  T0 = Process.clock_gettime(CLOCK)
  T0_REAL = Process.clock_gettime(Process::CLOCK_REALTIME)
  CPU0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  PID = Process.pid
  OUT = ENV.delete("HAYATE_PROBE_OUT")
  SPAWN_AT = ENV.delete("HAYATE_SPAWN_AT")
  PRE_FEATURES = $LOADED_FEATURES.size
  # 1 span = 7 スロット: kind, name, parent_index, t_start, t_end, feature/meta, thread_id
  W = 7
  EV = []
  MAIN = Thread.main
  STACK = []
  KIND_REQUIRE = 0; KIND_RR = 1; KIND_LOAD = 2; KIND_INIT = 3; KIND_ONLOAD = 4; KIND_EAGER = 5; KIND_BUNDLER = 6; KIND_PHASE = 7
  @on = true
  class << self; attr_accessor :on; end

  def self.stack
    t = Thread.current
    t.equal?(MAIN) ? STACK : (t.thread_variable_get(:__hayate_stack) || t.thread_variable_set(:__hayate_stack, []))
  end

  # yield の前後で span を開閉する。戻り値 / 例外はそのまま通す。
  def self.span(kind, name, meta = nil)
    return yield unless @on
    st = stack
    parent = st.last
    # alias chain が二重に通った場合 (同一 name オブジェクトの直下呼出) は記録しない
    return yield if parent && EV[parent + 1].equal?(name) && EV[parent + 4].nil? && kind <= KIND_LOAD && EV[parent] <= KIND_LOAD && EV.size == parent + W
    i = EV.size
    tid = st.equal?(STACK) ? 0 : Thread.current.object_id
    EV.push(kind, name, parent || -1, Process.clock_gettime(CLOCK), nil, meta, tid)
    st.push(i)
    ok = false
    begin
      r = yield
      ok = true
      r
    ensure
      EV[i + 4] = Process.clock_gettime(CLOCK)
      if kind <= KIND_LOAD
        EV[i + 5] = ok ? (r ? $LOADED_FEATURES.last : false) : :raised
        after_require(EV[i + 5]) if r && ok && !PENDING.empty?
      end
      st.pop
    end
  end

  # ---- 遅延インストール: feature のパス末尾 => インストーラ
  PENDING = {
    "/rails/initializable.rb" => -> { ::Rails::Initializable::Initializer.prepend(InitializerHook) },
    "/active_support/lazy_load_hooks.rb" => -> { ::ActiveSupport::LazyLoadHooks.prepend(OnLoadHook) },
    "/zeitwerk/loader.rb" => -> { ::Zeitwerk::Loader.prepend(EagerLoadHook) },
    "/bundler/runtime.rb" => -> { ::Bundler::Runtime.prepend(BundlerHook) },
    "/rails/application.rb" => -> { ::Rails::Application.prepend(AppHook) },
  }
  def self.after_require(feature)
    return unless feature.is_a?(String)
    PENDING.each_key do |suffix|
      next unless feature.end_with?(suffix)
      installer = PENDING.delete(suffix)
      begin
        installer.call
      rescue Exception => e # インストール失敗は計測の欠落に留め、boot は止めない
        (@errors ||= []) << "#{suffix}: #{e.class}: #{e.message}"
      end
    end
  end

  module InitializerHook
    def run(*args) = Hayate::Probe.span(KIND_INIT, name.to_s, @context.class.name) { super }
  end
  module OnLoadHook
    private def execute_hook(name, base, options, block)
      loc = block.source_location
      Hayate::Probe.span(KIND_ONLOAD, name.to_s, loc && "#{loc[0]}:#{loc[1]}") { super }
    end
  end
  module EagerLoadHook
    def eager_load(...) = Hayate::Probe.span(KIND_EAGER, tag.to_s) { super }
  end
  module BundlerHook
    def require(*groups) = Hayate::Probe.span(KIND_BUNDLER, "Bundler.require") { super }
  end
  module AppHook
    def initialize!(...) = Hayate::Probe.span(KIND_PHASE, "initialize!") { super }
  end

  # ---- require / load (alias chain)。prepend は使わない (docs/design/probe.md §1.3)
  BUILTIN_REQUIRE = Kernel.private_method_defined?(:gem_original_require) ? :gem_original_require : :__hayate_require
  [Kernel, Kernel.singleton_class].each do |k|
    k.class_eval do
      alias_method :__hayate_require, :require
      alias_method :require, :require
      def require(path) = Hayate::Probe.span(KIND_REQUIRE, path) { __hayate_require(path) }
      alias_method :__hayate_load, :load
      alias_method :load, :load
      def load(path, wrap = false) = Hayate::Probe.span(KIND_LOAD, path) { __hayate_load(path, wrap) }
    end
  end
  # require_relative も Kernel に直接定義する。Kernel への prepend は bootsnap の load path cache と組み合わさると
  # boot を数%遅くするため使わない (spike/04_probe/bench.sh, probe.md §1.4)。元メソッドは基準パスが正しく解決されないので呼ばない。
  ::Kernel.module_eval do
    alias_method :__hayate_require_relative, :require_relative
    alias_method :require_relative, :require_relative
    def require_relative(path)
      base = caller_locations(1, 1).first&.absolute_path or raise LoadError, "cannot infer basepath"
      abs = File.expand_path(path, File.dirname(base))
      Hayate::Probe.span(Hayate::Probe::KIND_RR, abs) { send(Hayate::Probe::BUILTIN_REQUIRE, abs) }
    end
  end
  Kernel.send(:private, :require, :__hayate_require, :load, :__hayate_load, :require_relative, :__hayate_require_relative)

  # ---- 書き出し (依存ゼロの最小 JSON)
  def self.j(v)
    case v
    when String then '"' + v.scrub.gsub(/["\\\u0000-\u001f]/) { |c| c == '"' ? '\\"' : c == "\\" ? "\\\\" : format("\\u%04x", c.ord) } + '"'
    when Symbol then j(v.to_s)
    when Integer then v.to_s
    when Float then v.finite? ? v.to_s : "null"
    when nil then "null"
    when true, false then v.to_s
    when Array then "[" + v.map { j(_1) }.join(",") + "]"
    when Hash then "{" + v.map { |k, x| j(k.to_s) + ":" + j(x) }.join(",") + "}"
    else j(v.to_s)
    end
  end

  def self.dump(status, error = nil)
    @on = false
    now = Process.clock_gettime(CLOCK)
    specs = defined?(::Gem) && ::Gem.respond_to?(:loaded_specs) ? ::Gem.loaded_specs.transform_values { [_1.version.to_s, _1.full_gem_path] } : {}
    root = defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : nil
    {
      v: 1, status: status, error: error, pid: PID, ruby: RUBY_VERSION, t0: T0, t0_real: T0_REAL, spawn_at: SPAWN_AT,
      cpu0: CPU0, t_exit: now, pre_features: PRE_FEATURES, features: $LOADED_FEATURES.size,
      width: W, events: EV.map { _1.is_a?(Float) ? _1 - T0 : _1 }, specs: specs, rails_root: root,
      probe_errors: @errors, pending: PENDING.keys,
    }
  end

  at_exit do
    next unless Process.pid == PID # fork した子の at_exit では書かない
    err = $!
    status = err.nil? || (err.is_a?(SystemExit) && err.success?) ? "ok" : "error"
    error = status == "error" ? { class: err.class.name, message: err.message.to_s[0, 2000], backtrace: Array(err.backtrace).first(20) } : nil
    data = j(dump(status, error))
    if OUT
      File.write("#{OUT}.tmp", data)
      File.rename("#{OUT}.tmp", OUT)
    else
      $stderr.puts "[hayate probe] status=#{status} spans=#{EV.size / W} bytes=#{data.bytesize}"
    end
  end
end
end
