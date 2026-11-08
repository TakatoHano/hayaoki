# frozen_string_literal: true

# hayaoki boot-report の probe (子プロセス側)。設計: docs/design/probe.md
#
#   ruby -r/path/to/hayaoki/probe.rb -e 'require "./config/environment"'
#
# - 依存ゼロ (json も require しない)。Ruby 3.2 の構文で書く。
# - require 系は alias chain で包む (Kernel には prepend しない。§1.3, §1.4)。
# - Rails 関連 (H4〜H9) は対象ファイルの require 直後に遅延 prepend する (§2.2)。
# - 結果は ENV["HAYAOKI_PROBE_OUT"] のパスへ tmp + rename で書く (§5)。
return if defined?(::Hayaoki::Probe::INSTALLED)

module Hayaoki; end

module Hayaoki::Probe
  CLOCK = Process::CLOCK_MONOTONIC
  T0 = Process.clock_gettime(CLOCK)
  T0_REAL = Process.clock_gettime(Process::CLOCK_REALTIME)
  CPU0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  PID = Process.pid
  OUT = ENV.delete("HAYAOKI_PROBE_OUT")
  SPAWN_AT = ENV.delete("HAYAOKI_SPAWN_AT")
  PRE_FEATURES = $LOADED_FEATURES.size
  GC_COUNT0 = GC.count
  GC_TIME0 = GC.stat(:time)

  # 1 span = W スロット: [kind, name, parent_idx, t_start, t_end, res, tid, cpu]
  W = 8
  EV = []
  MAIN = Thread.main
  MAIN_STACK = []
  # メイン以外のスレッドは専用バッファ (thread_variable) に記録し、write! で EV の後ろに結合する。
  BUFFERS = []
  BUF_LOCK = Mutex.new
  K_REQ = 0; K_RR = 1; K_LOAD = 2; K_INIT = 3; K_ONLOAD = 4; K_HOOKS = 5; K_EAGER = 6; K_PHASE = 7
  BUILTIN_REQUIRE = Kernel.private_method_defined?(:gem_original_require) ? :gem_original_require : :__hayaoki_require

  @on = true
  @false_count = 0
  # resolve_feature が名前から feature を見つけられず $LOADED_FEATURES.last を使った回数と例 (先頭 5 件)。
  # 他スレッドの require が末尾にあると帰属を間違えうるので、件数を出して気付けるようにする
  @fallbacks = 0
  @fallback_names = []
  @false_time = 0.0
  @boot_end = nil
  @errors = []
  @warnings = []
  @warnings << "gem_original_require not found; delegating require_relative to the builtin require" if BUILTIN_REQUIRE == :__hayaoki_require && defined?(::Gem::Specification)

  # --- recorder (ホットパス。ブロックを使わずフレームも増やさない) -----------------

  # span を開く。記録しない場合は nil を返す (その場合 leave は呼ばない)。
  def self.enter(kind, name)
    return unless @on
    t = Thread.current
    if t.equal?(MAIN)
      st = MAIN_STACK
      ev = EV
      tid = 0
    else
      st = t.thread_variable_get(:__hayaoki_stack) || t.thread_variable_set(:__hayaoki_stack, [])
      ev = t.thread_variable_get(:__hayaoki_buf) || new_buffer(t)
      tid = t.object_id
    end
    parent = st.last
    # alias chain のラッパーを同一引数のまま二重に通った場合は記録しない (§3.4)
    return if parent && kind <= K_LOAD && ev[parent] <= K_LOAD && ev[parent + 1].equal?(name) && ev[parent + 4].nil? && ev.size == parent + W
    i = ev.size
    ev.push(kind, name, parent || -1, Process.clock_gettime(CLOCK), nil, nil, tid, nil)
    st.push(i)
    i
  end

  # スレッド専用バッファを作る。初回だけ Mutex で全体のリストに登録する。
  def self.new_buffer(th)
    buf = []
    th.thread_variable_set(:__hayaoki_buf, buf)
    BUF_LOCK.synchronize { BUFFERS << buf }
    buf
  end

  # span を閉じる。res: require 系は feature / false / :raised、それ以外は meta / :raised。
  def self.leave(i, kind, res, cpu0 = nil)
    t = Process.clock_gettime(CLOCK)
    th = Thread.current
    main = th.equal?(MAIN)
    st = main ? MAIN_STACK : th.thread_variable_get(:__hayaoki_stack)
    ev = main ? EV : th.thread_variable_get(:__hayaoki_buf)
    st.pop
    if false.equal?(res) && kind <= K_LOAD && ev.size == i + W
      # false を返した require は span として残さず、回数と時間だけ数える (§3.5)
      BUF_LOCK.synchronize do
        @false_time += t - ev[i + 3]
        @false_count += 1
      end
      ev.pop(W)
      return
    end
    ev[i + 4] = t
    ev[i + 5] = res
    ev[i + 7] = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - cpu0 if cpu0
    @boot_end ||= t if main && st.empty? # 最初に閉じた深さ0 (= entry)。at_exit 内の require で延ばさない
    after_require(res) if kind <= K_RR && res.is_a?(String) && !PENDING.empty?
  end

  # 粗い span 用のブロック版 (initializer / on_load / eager_load / phase)。数百件だけで使う。
  def self.span(kind, name, meta = nil)
    return yield unless @on
    i = enter(kind, name)
    return yield unless i
    cpu0 = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
    ok = false
    begin
      r = yield
      ok = true
      r
    ensure
      leave(i, kind, ok ? meta : :raised, cpu0)
    end
  end

  # --- feature の解決 -----------------------------------------------------------
  # 他スレッドが同時に require すると $LOADED_FEATURES.last は自分のものとは限らない。
  # 速い方法は last が name に一致する場合、遅い方法は末尾から最大 SCAN_MAX 件を逆走査、
  # 見つからなければ last にフォールバックする (従来の挙動)。
  SCAN_MAX = 200

  # f が name の feature か。name は絶対パス (拡張子なしも可) か相対名。文字列は(ほぼ)割り当てない。
  def self.feature_match?(f, name)
    return false unless f.is_a?(String)
    n = name.bytesize
    fb = f.bytesize
    if name.getbyte(0) == 47 # 絶対パス: 完全一致、または name + ".ext"
      return fb == n ? f == name : (fb > n && fb - n <= 7 && f.getbyte(n) == 46 && f.start_with?(name) && !f.byteindex("/", n))
    end
    if name.getbyte(0) == 46 # "./x" や "../../x" は先頭の "./" と "../" を取り、"/x" の形で比べる
      k = 0
      while name.getbyte(k) == 46
        if name.getbyte(k + 1) == 47 then k += 2
        elsif name.getbyte(k + 1) == 46 && name.getbyte(k + 2) == 47 then k += 3
        else break
        end
      end
      if k.positive?
        name = name.byteslice(k - 1, n - k + 1) # 直前の "/" を含める
        n = name.bytesize
      end
    end
    # require "psych.so" は macOS では psych.bundle を読む (Ruby が .so を DLEXT に読み替える)。".so" を外して比べる
    if n > 3 && name.end_with?(".so") && (f.end_with?(".bundle") || f.end_with?(".dll"))
      name = name.byteslice(0, n - 3)
      n -= 3
    end
    # name が "/" で始まるなら区切りは name 自身に含まれる。そうでなければ直前が "/" であること
    sep = name.getbyte(0) == 47
    return true if !sep && fb == n && f == name
    # 「/name」で終わる (name が拡張子付き) か「/name.ext」で終わる
    return true if f.end_with?(name) && (sep || (fb > n && f.getbyte(fb - n - 1) == 47))
    dot = f.byterindex(".")
    # dot == n は feature 自体が "name.ext" の場合 (Ruby に組み込まれた拡張は "prism/prism.so" のように登録される)
    return false unless dot && dot >= n && (sep || dot == n || f.getbyte(dot - n - 1) == 47)
    f.byteindex(name, dot - n) == dot - n
  end

  def self.resolve_feature(name)
    name = name.to_path if !name.is_a?(String) && name.respond_to?(:to_path)
    return $LOADED_FEATURES.last unless name.is_a?(String)
    fl = $LOADED_FEATURES
    last = fl.last
    return last if feature_match?(last, name)
    i = fl.size - 2
    stop = fl.size - SCAN_MAX
    stop = 0 if stop < 0
    while i >= stop
      f = fl[i]
      return f if feature_match?(f, name)
      i -= 1
    end
    @fallbacks += 1
    @fallback_names << name if @fallback_names.size < 5
    last
  end

  # --- 遅延インストール (§2.2) --------------------------------------------------
  SELF_PATH = File.expand_path(__FILE__).freeze

  PENDING = {
    "/rails/initializable.rb" => :install_initializer,
    "/active_support/lazy_load_hooks.rb" => :install_on_load,
    "/zeitwerk/loader.rb" => :install_eager_load,
    "/bundler/runtime.rb" => :install_bundler,
    "/rails/application.rb" => :install_application,
    "/active_support/deprecation/reporting.rb" => :install_deprecation,
  }

  # require が true を返した直後に呼ぶ。$LOADED_FEATURES.last (= res) の末尾一致で判定する。
  def self.after_require(feature)
    PENDING.each do |suffix, installer|
      next unless feature.end_with?(suffix)
      PENDING.delete(suffix)
      run_installer(installer)
      break
    end
  end

  def self.run_installer(installer)
    send(installer)
  rescue Exception => e # インストールの失敗で boot を止めない
    @errors << "#{installer}: #{e.class}: #{e.message}"[0, 500]
  end

  def self.install_initializer = ::Rails::Initializable::Initializer.prepend(InitializerHook)
  def self.install_on_load = ::ActiveSupport::LazyLoadHooks.prepend(LoadHooksHook)
  def self.install_eager_load = ::Zeitwerk::Loader.prepend(EagerLoadHook)
  def self.install_bundler = ::Bundler::Runtime.prepend(BundlerHook)
  def self.install_application = ::Rails::Application.prepend(AppHook)
  def self.install_deprecation = ::ActiveSupport::Deprecation::Reporting.prepend(DeprecationHook)

  # probe が後から読み込まれた場合に備え、定義済みのものは即座にインストールする
  def self.install_defined
    {
      "/rails/initializable.rb" => -> { defined?(::Rails::Initializable::Initializer) },
      "/active_support/lazy_load_hooks.rb" => -> { defined?(::ActiveSupport::LazyLoadHooks) },
      "/zeitwerk/loader.rb" => -> { defined?(::Zeitwerk::Loader) },
      "/bundler/runtime.rb" => -> { defined?(::Bundler::Runtime) },
      "/rails/application.rb" => -> { defined?(::Rails::Application) },
      "/active_support/deprecation/reporting.rb" => -> { defined?(::ActiveSupport::Deprecation::Reporting) },
    }.each do |suffix, check|
      next unless PENDING.key?(suffix)
      ok = begin
        check.call
      rescue Exception
        false
      end
      run_installer(PENDING.delete(suffix)) if ok
    end
  end

  def self.loc(block)
    l = block.source_location
    l && "#{l[0]}:#{l[1]}"
  rescue StandardError
    nil
  end

  def self.label(obj)
    (obj.is_a?(Module) ? obj.name : obj.class.name).to_s
  rescue StandardError
    nil
  end

  # --- Rails 関連のフック (prepend 用) -----------------------------------------
  module InitializerHook
    def run(*args)
      meta = begin
        [@context.class.name, Hayaoki::Probe.loc(block)]
      rescue StandardError
        nil
      end
      Hayaoki::Probe.hook_eager_namespaces if name == :eager_load!
      Hayaoki::Probe.span(Hayaoki::Probe::K_INIT, name.to_s, meta) { super }
    end
  end

  # Finisher の eager_load! initializer は Zeitwerk の後で config.eager_load_namespaces.each(&:eager_load!) と
  # Rails.eager_load! を呼ぶ。TZInfo.eager_load! (zoneinfo を全部読む) のような require を伴わない重い処理が
  # ここに入るので、namespace ごとに K_EAGER span を作る。meta は元の eager_load! の定義位置 (持ち主の判定用)。
  module NamespaceEagerLoadHook
    def eager_load!(...)
      name = Hayaoki::Probe.label(self)
      # ActiveSupport::Autoload#eager_load! や Engine の delegate だと定義位置が共通の場所になるので、
      # 定数を定義したファイルを優先し、取れなければ元の eager_load! の位置を使う。
      loc = begin
        l = (Object.const_source_location(name) if name && !name.empty?)
        l = method(:eager_load!).super_method&.source_location if l.nil? || l.empty?
        l && !l.empty? ? "#{l[0]}:#{l[1]}" : nil
      rescue StandardError, NameError
        nil
      end
      Hayaoki::Probe.span(Hayaoki::Probe::K_EAGER, "#{name}.eager_load!", loc) { super }
    end
  end

  def self.hook_eager_namespaces
    list = ::Rails.application.config.eager_load_namespaces.to_a
    list << ::Rails
    list.uniq.each do |ns|
      next unless ns.respond_to?(:eager_load!)
      sc = ns.singleton_class
      sc.prepend(NamespaceEagerLoadHook) unless sc.include?(NamespaceEagerLoadHook)
    end
  rescue Exception => e # 計測の失敗で boot を止めない
    @errors << "eager_load_namespaces: #{e.class}: #{e.message}"[0, 500]
  end

  module LoadHooksHook
    def run_load_hooks(name, base = Object)
      Hayaoki::Probe.span(Hayaoki::Probe::K_HOOKS, name.to_s, Hayaoki::Probe.label(base)) { super }
    end

    private def execute_hook(name, base, options, block)
      Hayaoki::Probe.span(Hayaoki::Probe::K_ONLOAD, name.to_s, Hayaoki::Probe.loc(block)) { super }
    end
  end

  module EagerLoadHook
    def eager_load(...)
      Hayaoki::Probe.span(Hayaoki::Probe::K_EAGER, tag.to_s, nil) { super }
    end
  end

  module BundlerHook
    def require(*groups)
      Hayaoki::Probe.span(Hayaoki::Probe::K_PHASE, "bundler_require", groups) { super }
    end
  end

  # 非推奨警告の "called from" は Rails 自身のフレームを飛ばした最初のフレームになる。probe のフック
  # (initializer の run など) がそこに入ると警告の表示が変わるので、probe のファイルも飛ばさせる。
  # Rails 7.0 は ignored_callstack、7.1 以降は ignored_callstack?。
  module DeprecationHook
    private

    def ignored_callstack(path)
      path.to_s.start_with?(Hayaoki::Probe::SELF_PATH) || super
    end

    def ignored_callstack?(path)
      path.to_s.start_with?(Hayaoki::Probe::SELF_PATH) || super
    end
  end

  module AppHook
    def initialize!(...)
      Hayaoki::Probe.span(Hayaoki::Probe::K_PHASE, "initialize", nil) { super }
    end
  end

  # --- 出力 (§5) ---------------------------------------------------------------
  ESC = { '"' => '\\"', "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

  NEEDS_ESCAPE = /["\\\x00-\x1f]/

  # 自前の最小 JSON エンコーダ。対象は String / Symbol / Integer / Float / nil / true / false / Array / Hash。
  # 文字列の大半はエスケープ不要なので、確認だけして引用符で囲む速い方法を先に試す。
  def self.encode(v)
    case v
    when String
      s = v.encoding == Encoding::UTF_8 ? v : v.dup.force_encoding(Encoding::UTF_8)
      if s.valid_encoding?
        return "\"#{s}\"" unless s.match?(NEEDS_ESCAPE)
      else
        s = s.scrub
      end
      "\"#{s.gsub(/["\\\u0000-\u001f]/) { |c| ESC[c] || format("\\u%04x", c.ord) }}\""
    when Symbol then encode(v.to_s)
    when Integer then v.to_s
    when Float then v.finite? ? v.to_s : "null"
    when nil then "null"
    when true, false then v.to_s
    when Array
      return "[#{v.join(",")}]" if v.all?(Integer) # Integer だけの配列はまとめて連結する
      "[#{v.map { |x| encode(x) }.join(",")}]"
    when Hash then "{#{v.map { |k, x| "#{encode(k.to_s)}:#{encode(x)}" }.join(",")}}"
    else encode(v.to_s)
    end
  end

  def self.us(t) = ((t - T0) * 1_000_000).round

  # EV の後ろに各スレッドのバッファをオフセット付きで結合する (親の添字はバッファ内なのでずらす)。
  def self.events
    bufs = BUF_LOCK.synchronize { BUFFERS.dup }
    out = []
    base = 0
    [EV, *bufs].each do |ev|
      n = ev.size - ev.size % W
      j = 0
      while j < n
        par = ev[j + 2]
        out.push(
          ev[j], ev[j + 1].to_s, par < 0 ? par : par + base, us(ev[j + 3]), ev[j + 4] && us(ev[j + 4]),
          ev[j + 5], ev[j + 6], ev[j + 7] && (ev[j + 7] * 1_000_000).round
        )
        j += W
      end
      base += n
    end
    out
  end

  def self.specs
    return {} unless defined?(::Gem) && ::Gem.respond_to?(:loaded_specs)
    ::Gem.loaded_specs.to_h do |name, s|
      # extension_dir は gem ごとに約 0.3ms かかるため、ネイティブ拡張を持つ gem だけ解決する
      ext = begin
        s.extensions.empty? ? nil : s.extension_dir
      rescue StandardError
        nil
      end
      [name, [s.version.to_s, s.full_gem_path, ext]]
    end
  rescue StandardError => e
    @errors << "specs: #{e.class}: #{e.message}"[0, 500]
    {}
  end

  def self.rails_root
    return unless defined?(::Rails) && ::Rails.respond_to?(:root)
    ::Rails.root&.to_s
  rescue StandardError
    nil
  end

  def self.payload(status, error, now)
    own = $LOADED_FEATURES.count { |f| f.end_with?("/hayaoki/probe.rb") }
    grew = $LOADED_FEATURES.size - PRE_FEATURES - own
    if grew > 0 && @false_count == 0 && EV.empty? && BUFFERS.all?(&:empty?)
      @warnings << "$LOADED_FEATURES grew by #{grew} but no require was recorded (require may be overridden without alias_method)"
    end
    {
      v: 1, status: status, error: error, pid: PID, ruby: RUBY_VERSION, platform: RUBY_PLATFORM,
      t0_real: T0_REAL, spawn_at: SPAWN_AT, cpu0_us: (CPU0 * 1_000_000).round,
      boot_end_us: @boot_end && us(@boot_end), exit_us: us(now),
      pre_features: PRE_FEATURES, features: $LOADED_FEATURES.size,
      gc: { count0: GC_COUNT0, count1: GC.count, time0_ms: GC_TIME0, time1_ms: GC.stat(:time) },
      false_require: { count: @false_count, time_us: (@false_time * 1_000_000).round },
      resolve_fallbacks: { count: @fallbacks, examples: @fallback_names },
      width: W, events: events, specs: specs, rails_root: rails_root,
      pwd_realpath: (File.realpath(Dir.pwd) rescue nil),
      libdir: defined?(::RbConfig) ? [::RbConfig::CONFIG["rubylibdir"], ::RbConfig::CONFIG["rubyarchdir"]].compact : [],
      probe_errors: @errors, probe_warnings: @warnings, pending_hooks: PENDING.keys,
    }
  end

  # pid ガード付きで tmp に書いてから rename する。
  def self.write!
    return unless Process.pid == PID && OUT
    @on = false # 書き出し中の autoload などを記録しない
    now = Process.clock_gettime(CLOCK)
    err = $!
    ok = err.nil? || (err.is_a?(SystemExit) && err.success?)
    error = ok ? nil : { class: err.class.name, message: err.message.to_s[0, 2000], backtrace: Array(err.backtrace).first(20) }
    data = encode(payload(ok ? "ok" : "error", error, now))
    File.write("#{OUT}.tmp", data)
    File.rename("#{OUT}.tmp", OUT)
  rescue Exception => e # at_exit で例外を出して終了コードを変えない
    begin
      $stderr.puts "[hayaoki probe] write failed: #{e.class}: #{e.message}"
    rescue StandardError
      nil
    end
  end
end

# --- Kernel (alias chain。prepend は使わない) -------------------------------------
[::Kernel, ::Kernel.singleton_class].each do |k|
  k.class_eval do
    alias_method :__hayaoki_require, :require
    alias_method :require, :require # -w での再定義警告を抑止 (bootsnap と同じ手法)
    def require(path)
      i = Hayaoki::Probe.enter(0, path)
      ok = false
      r = __hayaoki_require(path)
      ok = true
      r
    ensure
      Hayaoki::Probe.leave(i, 0, ok ? (r && Hayaoki::Probe.resolve_feature(path)) : :raised) if i
    end

    alias_method :__hayaoki_load, :load
    alias_method :load, :load
    def load(path, wrap = false)
      i = Hayaoki::Probe.enter(2, path)
      ok = false
      r = __hayaoki_load(path, wrap)
      ok = true
      r
    ensure
      Hayaoki::Probe.leave(i, 2, ok ? path.to_s : :raised) if i
    end
  end
end

# require_relative は Kernel に直接定義し直す。元のメソッドは基準パスが正しく解決されないので呼ばず、
# gem_original_require (無ければ builtin の退避先) に委譲する (§1.4)。
::Kernel.module_eval do
  alias_method :require_relative, :require_relative
  def require_relative(path)
    loc = caller_locations(1, 1)&.first
    base = loc&.absolute_path
    # eval(code, binding, file) で実行されたコードは absolute_path が nil になる。ネイティブと同じく、渡された
    # file を (相対ならカレントディレクトリ基準で) 使う。-e も同じ扱い。file を渡さない eval だけ失敗させる
    # (Redmine は lib/plugins/*/init.rb をこの形で読む)
    base ||= File.expand_path(loc.path) if loc&.path && !loc.path.start_with?("(eval")
    raise LoadError, "cannot infer basepath" unless base
    abs = File.expand_path(path, File.dirname(base))
    i = Hayaoki::Probe.enter(1, abs)
    ok = false
    r = __send__(Hayaoki::Probe::BUILTIN_REQUIRE, abs)
    ok = true
    r
  ensure
    Hayaoki::Probe.leave(i, 1, ok ? (r && Hayaoki::Probe.resolve_feature(abs)) : :raised) if i
  end

  private :require, :load, :require_relative, :__hayaoki_require, :__hayaoki_load
end
::Kernel.singleton_class.send(:private, :__hayaoki_require, :__hayaoki_load)

Hayaoki::Probe.install_defined
at_exit { Hayaoki::Probe.write! }
Hayaoki::Probe::INSTALLED = true
