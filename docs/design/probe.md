# probe / recorder 詳細設計

- 対象: `hayaoki boot-report` の子プロセス側（probe）と、span を記録して親へ渡す部分（recorder）
- 対象環境: Ruby 3.2 以上、Rails 7.0 以上。検証は Ruby 4.0.6 / Bundler 4.0.16 / Rails 8.1.4 / bootsnap 1.26.1 / Zeitwerk 2.8.3 で行った
- 根拠となる実験: `spike/04_alias/`（require フック方式の比較）と `spike/04_probe/`（本設計のプロトタイプ）。結果は付録 A にまとめた

## 0. 結論の要約

1. **require 系のフックには prepend を使わず、alias chain（`alias_method` で退避して `require` を再定義する）で入れる。** `Kernel#require`、`Kernel.require`、`Kernel#load`、`Kernel.load` が対象。`require_relative` は Kernel に直接定義し直す（prepend しない）。
   - prepend を使う案は3つとも失敗する。素朴な prepend、spike 02 の暫定策（bind_call）、`Bundler::Runtime#require` だけを包む案のいずれも boot が失敗するか、bootsnap と Zeitwerk の require ラッパーを呼ばずに終わる。Zeitwerk が呼ばれないと、暗黙の名前空間（ファイルを持たない `app/models/admin/` など）を含むアプリで `LoadError` になる。
   - alias chain なら bundled_gems、bootsnap、Zeitwerk の alias chain と共存できる。どのラッパーも呼ばれ、bundled_gems の警告も残る。オーバーヘッドは +1.3〜1.4%（JSON 書き出しを含む）。
2. **Kernel には何も prepend しない。** 空のモジュールを prepend するだけで、bootsnap の load path cache が有効なときに boot が 3〜9% 遅くなった。
3. Rails 関連のフック（initializer、on_load、eager_load、Bundler.require、`initialize!`）は対象のクラスごとに prepend する。インストールは遅延させ、require が返った直後に `$LOADED_FEATURES.last` の末尾一致で判定する。
4. 記録はフラットな配列に1 span あたり固定長のスロットで追記する。時刻は `CLOCK_MONOTONIC`。`false` を返した require は span として残さず、回数と合計時間だけを数える。
5. 子から親へは、環境変数で渡したパスへのファイル書き出しで結果を返す（tmp に書いてから rename する）。boot 失敗時も部分結果を `status: "error"` 付きで書く。JSON は自前の最小エンコーダで生成し、`json` は require しない。

---

## 1. 事実4（`Kernel.require` の alias 退避問題）の決着

### 1.1 根本原因

`alias_method :new, :require` は**prepend されたモジュールのメソッドを含めて** `require` を探索し、見つかった本体を class の origin に複製する。実験（`spike/04_alias/01_alias_semantics.rb`）で確認した挙動は次のとおり。

| 対象 | prepend 後に alias chain された場合の挙動 |
|---|---|
| `Kernel`（instance） | 複製された Hook 本体の `super` が `no superclass method` になる |
| `Kernel.singleton_class` | 複製された Hook の `super` が後から定義された require に戻り、無限に再帰する |

実際の boot で後から `require` を alias chain するのは次の3者で、**instance 側も singleton 側も対象になる**。

- bundled_gems.rb の `replace_require`（Ruby 3.3 以上かつ Bundler 経由）: `[Kernel.singleton_class, Kernel]` の両方
- bootsnap の `load_path_cache/core_ext/kernel_require.rb`: `Kernel#require`
- Zeitwerk の `core_ext/kernel.rb`: `Kernel#require` と `class << self` の両方（`module_function`）

spike 02 で instance 側が失敗しなかったように見えたのは、失敗の仕方が「例外」ではなく「**呼ばれない**」だったためである。Zeitwerk が退避した `zeitwerk_original_require` は Hook の複製になり、bootsnap の `require` は Zeitwerk の `def require` に上書きされて呼ばれなくなっていた（付録 A-2 の呼出回数 0）。

さらに bundled_gems には**配線の交差**がある。`define_method` の中で `kernel_class.send(:no_warning_require, name)` を呼ぶため、次のようにつながる。

- instance 側の require は `Kernel.no_warning_require`、つまり **singleton の退避先**を呼ぶ。
- singleton 側の require は `Kernel.singleton_class.send(...)` を呼ぶ。メソッド探索は Class → Object → Kernel と進むので、**instance の `Kernel#no_warning_require`** に到達する。

`Bundler::Runtime#require` だけを包む案（instance だけ prepend し、singleton はフックしない）が失敗するのはこの交差のためである。Bundler.require は `Kernel.require` を呼び、そこから instance 側の Hook の複製に入って `super` で落ちる（付録 A-2 の `runtime`）。

### 1.2 案の比較（計測。`spike/04_alias/run_variants.sh`）

| 案 | 内容 | boot | bootsnap / Zeitwerk / bundled_gems のラッパー | bundled_gems の警告 | boot 時間（warm bootsnap） |
|---|---|---|---|---|---|
| naive | 両方に prepend して `super` | **失敗**（GemRequireError） | - | - | - |
| bindcall（spike 02 の暫定策） | singleton は probe 読込時の元メソッドを bind_call | **暗黙の名前空間で失敗**（ディレクトリの require が LoadError） | 0 / 0 / 0 回 | 消える | +10% |
| callee | `__callee__ != :require` なら元メソッドを bind_call | **暗黙の名前空間で失敗** | 0 / 0 / 2 回 | 消える | +10% |
| runtime | instance だけ prepend し、`Bundler::Runtime#require` を包む | **失敗**（1.1 の交差のため） | - | - | - |
| **chain（推奨）** | instance と singleton を alias chain で包む | 成功 | 1414 / 649 / 705 回 | 残る | **+1.2%** |

bindcall と callee は、暗黙の名前空間を持たない小さなアプリでは boot が通る。そのため気付きにくく、もっとも危険な案である。Zeitwerk は、ファイルを持たないディレクトリの autoload でディレクトリのパスを `Kernel#require` に渡し、自前のラッパーの中で処理する。このラッパーが呼ばれないと、RubyGems の require にディレクトリのパスが届いて `LoadError` になる。

### 1.3 推奨: alias chain 方式

```ruby
[::Kernel, ::Kernel.singleton_class].each do |k|
  k.class_eval do
    alias_method :__hayaoki_require, :require
    alias_method :require, :require          # -w での再定義警告を抑止（bootsnap と同じ手法）
    def require(path) ... __hayaoki_require(path) ... end
  end
end
```

この方式が失敗しにくい理由は次のとおり。

- **名前で呼ぶので super に依存しない。** 後から誰かが alias で退避すると、複製されるのは probe のラッパーである。複製の中身は `__hayaoki_require` を名前で呼ぶだけなので、どこに複製されても正しく動く。bundled_gems の交差した配線でも、どの呼び出しも probe のラッパーをちょうど1回通る（付録 A-4 で実際のスタックを確認した）。
- **後から入る上書きを消さない。** probe はチェーンの一番内側に入るので、外側の bootsnap、Zeitwerk、bundled_gems の処理はすべて実行される。bundled_gems の警告も残る。
- **後から prepend されても動く。** 他のライブラリが後で Kernel に prepend しても、`super` で origin に来ればチェーンをたどる。
- **バージョン差の影響を受けにくい。** Ruby 3.2 には `bundled_gems.rb` が無く（3.3 で追加）、Bundler 2.4 系も `replace_require` を呼ばない。これらの環境ではチェーンが短くなるだけで、probe のコードは変わらない。依存しているのは `alias_method` と再定義という Ruby 1.x 以来の挙動だけである。
- **読み込みが後になっても動く。** probe が他のライブラリより後に読み込まれた場合は、チェーンの一番外側に入る。

代償と対策は次のとおり。

| 代償 | 対策 |
|---|---|
| probe が一番内側にいるため、bootsnap のパス解決や Zeitwerk のコールバック（`__on_file_autoloaded`、Zeitwerk の `on_load`）の時間は親 span の self time に入る | 計測では無視できる量。設計上の性質として明記する |
| bootsnap が解決した絶対パスで呼ばれるため、`name` が元の require 文字列と一致しない（例: `slowgem/other` が `.../slowgem/other.rb` で届く） | span の同一性と gem への帰属には `feature`（`$LOADED_FEATURES.last`）を使い、`name` は表示用に留める |
| `alias_method` を使わずに `define_method :require` で上書きするライブラリがあると、フックが外れる | まれ。at_exit で「require が1件も記録されていないのに `$LOADED_FEATURES` が増えた」ことを検出して `probe_warnings` に載せる |
| `Kernel` に private メソッド名が3つ増える | §6.3 で扱う |

**`Bundler::Runtime#require` のフックは置き換えではなく追加として採用する。** これは Bundler.require 全体を表す phase span として使う。

### 1.4 `require_relative` も prepend しない

`require_relative` は誰も alias しないので、spike では Kernel に prepend していた。しかし、**`Kernel.prepend` は中身が空でも bootsnap の load path cache が有効なときに boot を遅くする**（付録 A-3: 空のモジュールで +24〜60ms。load path cache を無効にすると差は消える）。原因は特定していない。Kernel の origin が作られることで、bootsnap の Ruby 実装の require がメソッドを探索する処理が遅くなると推測している。

対策として、`require_relative` も Kernel に直接定義し直す（`__hayaoki_require_relative` に退避するだけで、元のメソッドは呼ばない）。この変更で、プロトタイプのオーバーヘッドは +12.0% から +1.4% に下がった。

委譲先は `gem_original_require` とする。事実2のとおり、`require` に委譲すると遅くなるうえに boot が失敗する。失敗の根本原因は未検証だが、RubyGems の require が既定 gem のファイルを require したときに spec を activate し、Bundler.setup と衝突するためだと推測している。

---

## 2. フックの一覧とインストール

### 2.1 一覧

| # | 対象 | 方式 | インストールの時点 | span の種類 | 記録する情報 |
|---|---|---|---|---|---|
| H1 | `Kernel#require` / `Kernel.require` | alias chain | probe 読み込み時 | require | name、feature、結果 |
| H2 | `Kernel#load` / `Kernel.load` | alias chain | probe 読み込み時 | require（`meta.load`） | path |
| H3 | `Kernel#require_relative` | 直接再定義 | probe 読み込み時 | require（`meta.relative`） | 絶対パス |
| H4 | `Bundler::Runtime#require` | prepend | `bundler/runtime.rb` の読み込み直後 | phase `bundler_require` | groups |
| H5 | `Rails::Application#initialize!` | prepend | `rails/application.rb` の読み込み直後 | phase `initialize` | - |
| H6 | `Rails::Initializable::Initializer#run` | prepend | `rails/initializable.rb` の読み込み直後 | initializer | name、`@context.class.name`、`block.source_location` |
| H7 | `ActiveSupport::LazyLoadHooks#execute_hook` | prepend | `active_support/lazy_load_hooks.rb` の読み込み直後 | on_load（`K_ONLOAD`） | フック名、`block.source_location` |
| H8 | `ActiveSupport::LazyLoadHooks#run_load_hooks` | prepend | H7 と同時 | load_hooks（`K_HOOKS`） | フック名、base のクラス名 |
| H9 | `Zeitwerk::Loader#eager_load` | prepend | `zeitwerk/loader.rb` の読み込み直後 | eager_load | `tag` |
| H9b | `config.eager_load_namespaces` の各要素と `Rails` の `eager_load!` | 特異クラスに prepend | H6 で `eager_load!` initializer を実行する直前 | eager_load（`<名前>.eager_load!`） | 定数の定義元（`Object.const_source_location`）、取れなければ元の `eager_load!` の位置 |
| H9c | `ActiveSupport::Deprecation::Reporting#ignored_callstack`（7.0）/ `#ignored_callstack?`（7.1 以降） | prepend | `active_support/deprecation/reporting.rb` の読み込み直後 | - | probe のファイルも Rails のフレームと同じく飛ばす。非推奨警告の "called from" が probe を指さないようにする |
| H10 | `Kernel#exit!` / `Process.exit!` | alias chain | probe 読み込み時（任意。§5.3） | - | 書き出してから委譲 |

補足:

- H9b について: Finisher の `eager_load!` initializer は Zeitwerk の後で `config.eager_load_namespaces.each(&:eager_load!)` と `Rails.eager_load!` を呼ぶ。`TZInfo.eager_load!`（zoneinfo を全部読む。macOS で約 115ms）のように require を伴わない処理があり、H9 だけでは initializer 本体の時間に埋もれていた。`ActiveSupport::Autoload#eager_load!` や Engine の delegate では定義位置が共通の場所になるため、持ち主の判定には定数の定義元を優先する。

- H4〜H9 は Kernel ではないので prepend で問題ない。後からこれらのメソッドを alias chain するライブラリは見つかっていない。万一あっても、複製された prepend 本体の `super` が失敗するのはそのライブラリの呼び出しだけである。リスクとして §9 に記載する。
- H7 について: `ActiveSupport` には `LazyLoadHooks` が extend 済みだが、Ruby 3.0 以降は後から prepend しても反映される（プロトタイプで on_load span が 40 件取れた）。
- H8 は「どの require や initializer が `:active_record` などの load hook を早期に発火させたか」を親の span から特定するためのグループ化に使う。H7 と H8 は別の種類の span（`K_ONLOAD` と `K_HOOKS`）として記録する。
- H9 について: Rails 8.1 は `Zeitwerk::Loader.eager_load_all` を呼び、7.x は `Rails.autoloaders.each(&:eager_load)` などを呼ぶ。どちらも `Loader#eager_load` に集約される。Zeitwerk 2.5 では `eager_load` が Loader の本体にあり、2.6 以降は `Loader::EagerLoad` にある。Loader に prepend すれば両方を捕捉できる。
- Rails の `eager_load!` initializer には、Zeitwerk 以外の `config.eager_load_namespaces.each(&:eager_load!)`（ActiveSupport::Autoload）も含まれる。この部分は initializer span の子の require として見える。プロトタイプでは、tzinfo のゾーン読み込みが initializer の self time 151ms として現れた（サンプリングで確認）。

### 2.2 遅延インストール

Rails や Bundler がまだ読み込まれていない段階では、「ファイルパスの末尾 → インストーラ」の表を持ち、require 系の span を閉じる時点で判定する。

```ruby
PENDING = {
  "/rails/initializable.rb"            => :install_initializer,
  "/active_support/lazy_load_hooks.rb" => :install_on_load,
  "/zeitwerk/loader.rb"                => :install_eager_load,
  "/bundler/runtime.rb"                => :install_bundler,
  "/rails/application.rb"              => :install_application,
}
# require 系の span を閉じるときに実行:
#   result が true かつ PENDING が空でなければ、$LOADED_FEATURES.last を末尾一致で照合する
```

- **判定は require が返った後**（ファイルの評価がすべて終わった後）に行う。この時点でクラスは定義済みである。対象のファイルを require_relative や autoload で読んでいても（Bundler は `autoload :Runtime` を使う）、H1 か H3 のどちらかを通るので漏れない。
- インストール済みのものは PENDING から削除する。PENDING が空になれば判定は 0 回で済む。
- インストーラは例外を握りつぶし、`probe_errors` に記録する。インストールの失敗で boot を止めない。
- probe の読み込み時にも一度だけ `defined?` で確認し、すでに定義済みのものは即座にインストールする。probe が後から読み込まれた場合や、`--no-r` の診断モードに備えるためである。
- 末尾一致の判定は、require 1回あたり最大5回の `String#end_with?` で済む。TracePoint の `:class` も検討したが、すべてのクラス本体で発火するため不採用とした。

### 2.3 インストールの順序と、他の上書きとの関係（Rails 8.1 / Ruby 4.0 で計測）

| 時点 | 起きること | フックの状態 |
|---|---|---|
| ruby 起動 | `gem_prelude` が RubyGems（`Kernel#require` の上書きと `gem_original_require` の alias）、did_you_mean、error_highlight、syntax_suggest を読み込む | - |
| `-r probe` | H1〜H3（と H10）をインストールし、at_exit を登録する。probe 自身の読み込みは記録しない | instance: probe → RubyGems → builtin / singleton: probe → builtin |
| `RUBYOPT` の `-r` | **コマンドラインの `-r` より後に処理される**（計測で確認）。利用者が `RUBYOPT=-rbundler/setup` を設定していても記録できる | - |
| `config/boot.rb` → `bundler/setup` | `bundler/runtime.rb` で H4。Bundler.setup → `replace_require`（Ruby 3.3 以上） | bundled_gems → probe |
| `bootsnap/setup` | load path cache が `Kernel#require` を alias chain する。compile cache は iseq の読み込みに介入するだけなので無関係 | bootsnap → bundled_gems → probe |
| `require "rails"` | `lazy_load_hooks.rb` で H7・H8、Zeitwerk の core_ext で instance と singleton を alias chain、`zeitwerk/loader.rb` で H9、`rails/initializable.rb` で H6、`rails/application.rb` で H5 | instance: Zeitwerk → bootsnap → bundled_gems → `Kernel.no_warning_require`（singleton の probe）→ builtin |
| `Bundler.require` | H4 の span の中で、gem ごとに `Kernel.require` を呼ぶ | singleton: Zeitwerk → bundled_gems → `Kernel#no_warning_require`（instance の probe）→ RubyGems |
| `initialize!` | H5 の span の中で H6・H7・H9 の span が入れ子になる | - |
| 終了時 | 他の at_exit を実行した後、**最初に登録した probe の at_exit が最後に実行される** | - |

boot の終了時刻は at_exit の時刻ではなく、**main スレッドの深さ0の span（`-e` の `require './config/environment'`）が閉じた時刻**とする。他のライブラリの at_exit（minitest など）の時間を含めないためである。

---

## 3. span の木の構築

### 3.1 スタックの管理

- 各 span は開いた時点で記録配列に追記する（先行順）。親は**記録配列の添字**で持つ。`children` の配列は作らず、親プロセスで復元する（§4.2）。
- スタックには開いている span の添字を積む。開くときに `parent = stack.last` とする。
- 閉じる処理は `ensure` で行う。例外、`throw`、`break` のいずれでも必ず pop され、終了時刻と結果が書き込まれる。

### 3.2 例外

- 例外で抜けた span には `res = :raised` を記録し、**span 自体は残す**。boot 失敗時には、raised の span をたどれば失敗した呼び出し（どの initializer の、どの require か）が分かる。
- 例外を握りつぶした上位の span は通常どおり閉じる（プロトタイプの edge テストで確認済み）。
- 例外オブジェクトは保持しない（メモリ節約のため）。boot 全体の失敗は at_exit の `$!` から取得する。

### 3.3 マルチスレッド

- スタックは**スレッドごと**に持つ。main スレッドでは定数 `MAIN_STACK` を直接使い（高速な方法）、それ以外のスレッドでは `Thread#thread_variable_get(:__hayaoki_stack)` を使う。`Thread.current[]` は fiber ローカルなので使わない。
- 記録配列 `EV` はメインスレッドだけが使う。main 以外のスレッドは、スレッドごとのバッファ（`Thread#thread_variable_get(:__hayaoki_buf)`）に記録する。バッファの一覧 `BUFFERS` は `BUF_LOCK` で保護して登録する。書き出し時に `EV` の後ろへ各バッファを結合し、親の添字はバッファ内の位置からずらす（`Hayaoki::Probe.events`）。1 span ぶんの追記は**1回の `Array#push(複数の引数)`** で行う（バッファ内でも同じ）。
- span には `tid` を記録する（main は 0、それ以外は `Thread#object_id`）。親では main 以外の span を「background threads」という別の根として表示し、boot 全体の合計（クリティカルパス）には含めない。
- 注意: 時間はすべて wall clock なので、並行するスレッドが GVL を奪った時間も main の span に入る。require の loading lock を待つ時間も含まれる。親はスレッドの span が1件でもあれば「並行実行あり、時間の帰属は近似」と注記する。
- Fiber の中で require された場合は、そのスレッドのスタックに積まれる。Fiber を切り替えながら require が交互に進むと入れ子の関係が崩れるが、boot 中にはまず起きないので許容する。

### 3.4 require_relative と require の二重記録

- H3 は `gem_original_require` に直接委譲し、H1 を通らない。そのため require_relative が H1 で二重に記録されることはない。
- alias chain の交差により、将来 probe のラッパーが2回通る呼び出しができた場合の防御として、probe 側でガードする。「直前に開いた span が require 系で、まだ子が無く（`EV.size == parent + W`）、`name` が同一オブジェクトである」ときは記録せずに通す。これは参照の比較だけなので安い。
- 親側でも正規化する。require 系の span が**唯一の子**として同じ feature の require 系の span を持つ場合は、2つを1つにまとめる。bootsnap などが名前を書き換えて同一オブジェクトの判定をすり抜けたときの保険である。

### 3.5 `false` を返した require

- **span としては残さない。** 閉じる時点で結果が `false` なら、自分の分のスロットを取り除き（直前に追記した span なので `EV.pop(W)`）、`FALSE_COUNT` と `FALSE_TIME` に加算する。計測では 907 件で合計 5.1ms（boot の 0.7%）、最大 0.86ms だった。span 数は約4割減る。
- `false` を返す require は子を持たない。循環 require が途中で戻るときも子は無い。そのため取り除いても木は崩れない。
- 時間は自然に親の self time に入る。合計値は診断用に出力する（「`false` を返す require が多い」というルールの材料になる）。
- 例外で抜けた require は 3.2 のとおり残す。

### 3.6 on_load のネストと時間の帰属

- 時間は**包含的に記録**し、self time は `duration - Σchildren` で求める。よくある入れ子と帰属は次のとおり。
  - `require "action_controller/base"` → 末尾の `run_load_hooks(:action_controller)`（H8）→ 各 `execute_hook`（H7） → フックの中の require …
  - actionpack の require の self time からフックの時間は除かれ、フックの self time はそのブロックの持ち主（`source_location` から判定した gem）に帰属する。
  - フックの中の require は、その require 先の gem に帰属する。
- 親が出す見方は2つある。
  1. **自己帰属**: self time を持ち主ごとに合計する。gem ランキングの既定。
  2. **起因帰属**: 持ち主ごとに「最も外側の自分の span の inclusive 時間」を合計する。「この gem の on_load が引き起こした読み込み」を改善の候補として出すときに使う。
- on_load のブロックが別の load hook を発火させた場合は、H8 → H7 が入れ子になる。どちらの時間も二重に数えない（self time の定義による）。
- `with_execution_control` で実行されなかったブロック（`run_once` で2回目のもの）も H7 は通るが、ブロックが実行されないので、ほぼ 0ms の span になる。親で 0.05ms 未満の on_load を畳んで表示する。

---

## 4. 時刻と記録形式

### 4.1 clock

| 用途 | clock | 理由 |
|---|---|---|
| span の開始と終了 | `Process.clock_gettime(Process::CLOCK_MONOTONIC)`（Float 秒） | 単調増加。64bit では Float が flonum になるので割り当てが発生しない |
| CPU 時間（粗い span のみ） | `CLOCK_THREAD_CPUTIME_ID` | initializer の「外部 I/O 待ち」を検出するため（wall と cpu の差） |
| Ruby VM の起動時間の推定 | 親の spawn 直前と probe の先頭で `CLOCK_REALTIME`。補助として probe の先頭で `CLOCK_PROCESS_CPUTIME_ID` | 2つのプロセスにまたがるため realtime を使う。計測で realtime の差が 28.2ms、CPU 時間が 26.9ms と整合した |
| GC | `GC.stat(:time)` と `GC.count` を probe の開始時と終了時に取る | GC チューニングのルールの材料（span ごとには取らない） |

- CPU 時間は、initializer、on_load、eager_load、phase の span（数百件）でだけ取る。require の span（数千件）では取らない。開始値はメソッドのローカル変数に持ち、閉じるときに差分だけを記録する。
- 親から子へは `HAYAOKI_SPAWN_AT`（realtime の Float 文字列）を渡す。VM の起動時間は `t0_real - spawn_at` で推定する。親は同じ ruby で `ruby -e ''` を数回実行した値も参考として表示する。

### 4.2 記録形式（フラットな配列）

```
EV = []   # 1 span = W(=8) スロット
# [kind, name, parent_idx, t_start, t_end, res, tid, cpu]
#  kind     : 0=require 1=require_relative 2=load 3=initializer 4=on_load 5=load_hooks 6=eager_load 7=phase
#  name     : require 系は引数（String/Pathname をそのまま参照）、それ以外は名前
#  parent   : 親の span の EV 添字（根は -1）
#  t_start/t_end : MONOTONIC の Float。t_end が nil なら未完了
#  res      : require 系は feature(String) / :raised。それ以外は meta（source_location の "path:line" や context のクラス名）
#  tid      : 0=main、それ以外は Thread#object_id
#  cpu      : CPU 秒（粗い span のみ。それ以外は nil）
```

- Hash や Struct は作らない。1 span あたりの割り当ては実質0で、`Array#push` が1回とメソッド呼び出しが数回で済む。プロトタイプでは 1 span あたり約5µs（JSON 書き出しを含む）だった。
- name と feature は**参照だけを保持**し、dup しない。`$LOADED_FEATURES` の要素は frozen である。呼び出し側が後で文字列を破壊的に変更する可能性はほぼ無いが、書き出し時に `to_s` する。
- 書き出し時に、時刻を `T0` 基準の整数マイクロ秒に変換する（ペイロードを小さくするため）。
- 大規模アプリ（require が数万件）では JSON が数 MB になる。name と feature を文字列表に集めて添字で参照する形式を v2 の候補とする。v1 ではプロトタイプで 1.4〜2.1k span、約 420KB だった。

---

## 5. 子プロセスから親への受け渡し

### 5.1 出力先

- **環境変数 `HAYAOKI_PROBE_OUT` で渡したファイルパスに書き出す。** 親は `Dir.mktmpdir` の中に run ごとのファイル名を用意する。
  - pipe（fd 3 などの継承）は採用しない。アプリが fd を閉じたりデーモン化したりすると失敗しやすく、親が読み出しを並行させる必要もあるため。
  - stdout と stderr はアプリのログと一緒になるので使わない。親はこれらを上限付きで捕捉し、失敗時の表示にだけ使う。
- 書き出しは `"#{OUT}.tmp"` に書いてから `File.rename` する。途中で kill されても、不完全な JSON を親が読まないようにするためである。
- probe は起動時に `ENV.delete("HAYAOKI_PROBE_OUT")` と `ENV.delete("HAYAOKI_SPAWN_AT")` を実行し、値は定数に保持する。子孫のプロセスへの引き継ぎと、アプリから見える副作用を最小にするためである。
- **pid のガード**: probe の読み込み時の `Process.pid` を保持し、at_exit で一致したときだけ書く。boot 中に fork した子（spring、preload、`Process.fork` を使う initializer など）が結果を上書きしないようにするためである（edge テストで確認済み）。

### 5.2 at_exit と部分結果

| 状況 | at_exit | 結果 |
|---|---|---|
| 正常終了 | 実行される | `status: "ok"` |
| 例外による boot 失敗 | 実行される（`$!` が設定されている） | `status: "error"`、`error: {class, message(2000字まで), backtrace(20行まで)}`、**部分的な木**（raised の span を含む） |
| `exit 1` / `abort` | 実行される | `$!` が `SystemExit` で `success?` が false なら `"error"` |
| SIGTERM（親のタイムアウトによる1回目の kill） | 実行される（SignalException） | `"error"`。開いていた span は ensure で raised として閉じるので、**どこで止まっていたか**が分かる |
| `exit!`、SIGKILL、segfault、`exec` | 実行されない | ファイルが無い。親は「結果なし」として扱い、stderr の末尾を表示する |

- 部分結果は**返す**。親は失敗した run を除外して続行する（中央値の集計から外し、残りの run で計測を続ける）。診断用に「失敗した位置」（raised の span の連なりと、未完了の span）を表示する。**全 run が失敗した場合のみエラー**とし、1回目の部分結果とエラーを表示して終了コードを非0にする。
- 未完了の span（`t_end` が nil）は、親が `t_exit` で閉じて `meta.incomplete` を付ける。

### 5.3 `exit!` への対応（任意、P2）

- `Kernel#exit!` と `Process.exit!` を alias chain で包み、書き出しを済ませてから委譲する（`status: "exit!"`）。boot 中の `exit!` はまれなので、v1 では入れなくてもよい。入れる場合も、Kernel への prepend は §1.4 の理由で禁止する。
- events を逐次ファイルに追記する方式（SIGKILL でも残る）はオーバーヘッドがあるので採用しない。必要になったらデバッグ用の環境変数で有効にする案に留める。

### 5.4 JSON の生成（json を require しない）

- **自前の最小エンコーダ（約25行）を使う。** `json` を遅延 require する案は次の理由で採用しない。
  1. Bundler の制約下では、Gemfile.lock が別のバージョンの json を指定していることがある。activate による衝突や警告のおそれがある。
  2. boot が json の読み込みの途中で失敗していると、json が半端な状態になっている。
  3. ActiveSupport は `to_json` の系統を書き換えるので、生成結果が環境によって変わりうる。
  4. require すれば、その時間とファイルが計測の対象に含まれる（事実5）。書き出し前に記録を止めれば避けられるが、上の3点は残る。
- 扱う型は String、Symbol、Integer、Float、nil、true/false、Array、Hash に限る。String は `scrub` した後、`"`、`\`、制御文字だけをエスケープする。Float は時刻を整数 µs にするので基本的に出てこない。それ以外の型は `to_s` する。
- 書き出しの前に `@on = false` として記録を止める。エンコーダの中で autoload などが起きても記録されない。

### 5.5 出力スキーマ（v1）

```json
{
  "v": 1, "status": "ok|error|exit!", "error": null,
  "pid": 123, "ruby": "4.0.6", "platform": "arm64-darwin25",
  "t0_real": 1762500000.123, "spawn_at": "1762500000.095", "cpu0_us": 26900,
  "boot_end_us": 634200, "exit_us": 640000,
  "pre_features": 58, "features": 1490,
  "gc": {"count0": 3, "count1": 21, "time0_ms": 2, "time1_ms": 48},
  "false_require": {"count": 907, "time_us": 5100},
  "width": 8, "events": [0, "./config/environment", -1, 120, 634200, "/app/config/environment.rb", 0, null, ...],
  "specs": {"rails": ["8.1.4.1", "/gems/rails-8.1.4.1", "/gems/extensions/.../rails-8.1.4.1"], "...": []},
  "rails_root": "/app", "pwd_realpath": "/private/app",
  "libdir": ["/opt/ruby/lib/ruby/4.0.0", "/opt/ruby/lib/ruby/4.0.0/arm64-darwin25"],
  "probe_errors": [], "probe_warnings": [], "pending_hooks": []
}
```

- `specs` は at_exit 時点の `Gem.loaded_specs` から作る（名前 → [version, full_gem_path, extension_dir]）。gem への帰属は親で行う。比較は最長接頭辞で、`full_gem_path` と `extension_dir` の両方を見る。`Rails.root` 配下の path gem（`vendor/slowgem` など）は最長一致の規則で app ではなく gem になる。どの gem にも一致せず `libdir` 配下なら stdlib とする。macOS の `/tmp` → `/private/tmp` などは親が `File.realpath` をディレクトリ単位でキャッシュして正規化する。
- `pending_hooks` に残ったものは、Rails 以外のアプリなど、対象のファイルが読み込まれなかったことを表す。

---

## 6. ファイル構成とシグネチャ

### 6.1 構成

- `lib/hayaoki/probe.rb` の**1ファイル**。依存は0で、Ruby 3.2 の構文で書く（`it` やパターンマッチの新しい機能は使わない）。
- `lib/hayaoki.rb` からは require しない。Runner は `File.expand_path("hayaoki/probe.rb", __dir__)` の絶対パスを `-r` に渡す。gem をインストールしたディレクトリにあるので、Gemfile に追加しなくても読み込める。
- 冒頭を `return if defined?(::Hayaoki::Probe::INSTALLED)` とし、二重に読み込まれても何もしない（アプリの Gemfile に hayaoki が入っている場合への備え）。

### 6.2 擬似コード

```ruby
# frozen_string_literal: true
module Hayaoki; end              # gem 本体と同じく module（class にはしない）
module Hayaoki::Probe
  CLOCK = Process::CLOCK_MONOTONIC
  T0 = Process.clock_gettime(CLOCK); T0_REAL = ...; CPU0 = ...; PID = Process.pid
  OUT = ENV.delete("HAYAOKI_PROBE_OUT"); SPAWN_AT = ENV.delete("HAYAOKI_SPAWN_AT")
  W = 8; EV = []; MAIN = Thread.main; MAIN_STACK = []
  K_REQ = 0; K_RR = 1; K_LOAD = 2; K_INIT = 3; K_ONLOAD = 4; K_HOOKS = 5; K_EAGER = 6; K_PHASE = 7
  BUILTIN_REQUIRE = Kernel.private_method_defined?(:gem_original_require) ? :gem_original_require : :__hayaoki_require
  @on = true

  # --- recorder（ホットパス。ブロックを使わず、フレームも増やさない）
  def self.enter(kind, name) -> Integer | nil        # 記録しない場合は nil
  def self.leave(i, kind, res, cpu0 = nil) -> void   # res: feature / false / :raised
  def self.stack -> Array                             # main なら MAIN_STACK
  def self.after_require(feature) -> void             # PENDING の照合とインストール

  # --- 粗い span 用（ブロック版。initializer、on_load などの数百件だけで使う）
  def self.span(kind, name, meta) { ... } -> 戻り値はブロックの値

  # --- Rails 関連のフック（prepend 用。すべて Hayaoki::Probe の下に閉じ込める）
  module InitializerHook; def run(*args) = Probe.span(K_INIT, name.to_s, ...) { super }; end
  module LoadHooksHook
    def run_load_hooks(name, base = Object) = Probe.span(K_HOOKS, name.to_s, ...) { super }
    private def execute_hook(name, base, options, block) = Probe.span(K_ONLOAD, name.to_s, loc(block)) { super }
  end
  module EagerLoadHook; def eager_load(...) = Probe.span(K_EAGER, tag.to_s, nil) { super }; end
  module BundlerHook;  def require(*groups) = Probe.span(K_PHASE, "bundler_require", groups) { super }; end
  module AppHook;      def initialize!(...) = Probe.span(K_PHASE, "initialize", nil) { super }; end

  # --- 出力
  def self.encode(obj) -> String     # 最小 JSON
  def self.payload(status, error) -> Hash
  def self.write! -> void            # pid ガード、tmp に書いて rename
end

# --- Kernel（alias chain）
[Kernel, Kernel.singleton_class].each do |k|
  k.class_eval do
    alias_method :__hayaoki_require, :require; alias_method :require, :require
    def require(path)
      i = Hayaoki::Probe.enter(0, path)          # 0 = K_REQ
      ok = false
      r = __hayaoki_require(path)
      ok = true
      r
    ensure
      Hayaoki::Probe.leave(i, 0, ok ? (r && $LOADED_FEATURES.last) : :raised) if i
    end
    # load も同じ形。引数は (path, wrap = false)
  end
end
Kernel.module_eval do
  alias_method :__hayaoki_require_relative, :require_relative; alias_method :require_relative, :require_relative
  def require_relative(path)
    base = caller_locations(1, 1).first&.absolute_path or raise LoadError, "cannot infer basepath"
    abs = File.expand_path(path, File.dirname(base))
    # 以降は require と同じ enter/leave の形で send(Hayaoki::Probe::BUILTIN_REQUIRE, abs) に委譲する
  end
  private :require, :load, :require_relative, :__hayaoki_require, :__hayaoki_load, :__hayaoki_require_relative
end
at_exit { Hayaoki::Probe.write! }
Hayaoki::Probe::INSTALLED = true
```

- **ホットパスを inline 化する理由**: プロトタイプのブロック版 `span { }` は利用者のバックトレースに require 1回あたり3フレーム（`Kernel#require`、`block in Kernel#require`、`Hayaoki::Probe.span`）を追加する。enter と leave の形にすれば1フレームで済み、メソッド呼び出しとブロックの生成も減る。bundled_gems の `uplevel` 計算や ActiveSupport::Deprecation が `caller` から呼び出し元を推定する処理への影響も小さくなる。

### 6.3 名前空間の汚染を最小にする方針

| 追加するもの | 範囲 |
|---|---|
| 定数 | `::Hayaoki` と `::Hayaoki::Probe` のみ。フック用のモジュールは `Hayaoki::Probe::*` の下に置く |
| Kernel のメソッド | private の `__hayaoki_require`、`__hayaoki_load`、`__hayaoki_require_relative`（instance と singleton。`require_relative` は instance のみ）。名前は RubyGems の `gem_original_require` にならった |
| prepend 先 | §2.1 の H4〜H9 だけ。追加するのは `super` を呼ぶだけの公開メソッドで、インスタンス変数は追加しない |
| その他 | グローバル変数は使わない。スレッド変数は `:__hayaoki_stack`（スタック）と `:__hayaoki_buf`（スレッドごとの記録バッファ）の2つ。環境変数は読み込み時に削除する |
| 書き出し時に読む情報 | `Gem.loaded_specs` と `Rails.root` は `defined?` と `respond_to?` で確認してから読む。autoload を引き起こす参照（`Rails.application.config` など）は行わない |

---

## 7. エッジケース

| ケース | 扱い |
|---|---|
| `--disable-gems` | `gem_original_require` が無いので、`BUILTIN_REQUIRE = :__hayaoki_require`（builtin の退避先）にする。後で `require "rubygems"` されると、RubyGems の `alias_method :gem_original_require, :require` は probe のラッパーを退避するが、名前で呼ぶので正しく動く（edge テストで確認済み）。親が `--disable-gems` で起動することは無いが、`RUBYOPT` にこれが含まれていても動く |
| `gem_original_require` が無い（RubyGems の仕様変更） | 上と同じ代替先に切り替える。`probe_warnings` に記録する |
| bootsnap | 無効にしない。warm cache の状態が実際の運用に近いので、Runner は1回目を捨てるウォームアップを推奨する。cold 計測は Runner が `BOOTSNAP_CACHE_DIR` を run ごとの tmp にして行う（probe は関与しない）。bootsnap の有無はどちらでもオーバーヘッドが約 +1.3% だった |
| Spring | `-e "require './config/environment'"` は binstub を通らないので Spring は介在しない。念のため Runner は `DISABLE_SPRING=1` を付ける。`Bundler.require` で spring gem が読み込まれても、Spring のクライアントは起動しない |
| `RUBYOPT` の継承 | probe は `RUBYOPT` を使わずに `-r` で読み込まれるので、子孫プロセスには載らない。利用者の `RUBYOPT`（`with_unbundled_env` が復元する元の値）は尊重し、その `-r` は probe より後に処理されるので計測できる。`HAYAOKI_*` は probe が削除する。boot 中に `exec` で別の ruby に置き換わる構成（Bundler の再 exec など）では結果が出ない。親はこれを「結果なし」として検出し、案内を出す |
| fork | §5.1 の pid ガードで対応する |
| Rails 以外の Bundler アプリ | probe はフレームワークに依存しない。Rails のフックはインストールされずに `pending_hooks` に残るだけで、require と Bundler.require の span は取れる。Runner 側で起動コマンドを `-e "require 'bundler/setup'; Bundler.require"` または `--entry FILE` に切り替えられるようにする |
| `Kernel.require` を直接呼ぶコード | singleton の alias chain で捕捉できる（Bundler.require もこの呼び出しを通る） |
| `autoload`（Zeitwerk 以外も含む） | CRuby の autoload は、`Kernel#require` が再定義されているとそのメソッドを呼ぶので H1 を通る（事実1） |
| Pathname などの非 String の引数 | 参照をそのまま保持し、書き出し時に `to_s` する |
| シンボリックリンクを含むディレクトリでの `require_relative` | `caller_locations(...).absolute_path` が realpath を返すので、ネイティブの解決と一致する（Ruby 4.0 で確認。`spike/04_probe/edge/symlink_rr.sh`）。**3.2〜3.4 では未検証** |
| `eval` の中の `require_relative` | `absolute_path` が nil になるので、ネイティブと同じく `LoadError "cannot infer basepath"` を出す |
| Ractor（3.4 以降） | 非 main の Ractor から require されると、共有できない定数（EV など）を参照して `Ractor::IsolationError` になる可能性がある。boot 中にはまず起きない。リスクとして記録する |
| probe が後から読み込まれた | alias chain が一番外側に入るだけで動く。カバレッジは下がる（事実3）。遅延インストールの対象は `defined?` で確認して即座にインストールする |

---

## 8. テスト方針

### 8.1 正確性（既知の sleep を入れたダミー gem）

`spike/04_alias/setup_app.sh` を元にした fixture アプリ `test/fixtures/apps/rails_N` を用意する。

- `vendor/slowgem`（path gem）
  - `slowgem.rb`: `sleep 0.10` のあと `require_relative "slowgem/inner"`（50ms）と `require "slowgem/other"`（30ms）を実行し、`on_load(:action_controller) { sleep 0.04 }` を登録する
- `config/initializers/spike.rb`: `sleep 0.02` を実行し、on_load を登録する
- `app/models/admin/thing.rb`（**暗黙の名前空間**。§1.2 の回帰テストを兼ねる）
- 判定（許容誤差は sleep の精度を考えて +15ms / -1ms）:
  - slowgem の self time ≈ 100ms、inner ≈ 50ms（require_relative として1件だけ）、other ≈ 30ms
  - on_load(action_controller) ≈ 40ms で、持ち主は slowgem
  - `spike.rb` の load span ≥ 19ms、かつそれを含む initializer（`load_config_initializers`）の inclusive 時間 ≥ 19ms（Rails は設定ファイルを `load` で読むため、その時間は子の load span に入り、initializer の self time には現れない）
  - プロトタイプで計測した値は slowgem 105.3 / 55.2 / 35.6ms、on_load 45.0ms
- 帰属: slowgem の span は Rails.root 配下にあるが、gem として帰属する。
- boot を壊さないこと: probe の有無で `Rails.application.initialized?`、bundled_gems の警告の文言、`$LOADED_FEATURES` の集合が一致すること。

### 8.2 フックの順序と共存（Rails を使わない単体テスト）

- 素の Ruby で次の5通りの読み込み順を作り、require がちょうど1回だけ記録され、各ラッパーがちょうど1回呼ばれることを確認する（`spike/04_alias/probe_variants.rb` と同じく TracePoint で呼出回数を数える）。
  1. probe → bundled_gems の `replace_require` → bootsnap → Zeitwerk
  2. 1 の逆順（probe が最後）
  3. probe → 他のライブラリが Kernel に prepend
  4. `--disable-gems` → probe → `require "rubygems"`
  5. probe を2回読み込む
- 例外、スレッド、fork、`exit!`、SIGTERM の挙動を確認する（`spike/04_probe/edge/run_edge.sh` を minitest に移植する）。
- JSON エンコーダ: 制御文字、非 UTF-8 のバイト列、Pathname を含む値を `JSON.parse`（テスト側でのみ使用）で往復させる。

### 8.3 オーバーヘッド（回帰テスト）

- `spike/04_probe/bench.sh` と同じく、probe の有無を交互に N=15 回実行して中央値を比べる。bootsnap の有無の両方で行う。基準は **中央値 +3% 以内、p90 +5% 以内**。超えたら CI を失敗させる（ノイズを考えて nightly で実行する）。
- 「Kernel に prepend しない」ことを静的なテストで保証する（`Kernel.ancestors.first == Kernel`）。

### 8.4 バージョンマトリクス（CI。Docker イメージ `ruby:X.Y`）

| Ruby | Bundler | Rails | 主に確認すること |
|---|---|---|---|
| 3.2 | 2.4 / 2.5 | 7.0、7.1 | bundled_gems が無い環境、Zeitwerk 2.6、`absolute_path` の realpath |
| 3.3 | 2.5 | 7.1、7.2 | `replace_require` の初出 |
| 3.4 | 2.6 | 7.2、8.0 | Ractor の require、bundled gems の警告の増加 |
| 4.0 | 4.0 | 8.0、8.1 | 本設計の検証環境 |
| head | 最新 | main | 早期警告用（失敗を許容） |

- 各セルで、bootsnap あり / なしと、`config.eager_load` true / false を組み合わせる。
- 加えて、実在する中規模の OSS Rails アプリ（discourse、mastodon など）で boot を壊さないことを smoke test で確認する（nightly）。

---

## 9. 未解決のリスクと、実装時に検証すること

1. **Ruby 3.2〜3.4 での動作は未検証。** 今回の環境には Ruby 4.0 しか無い。alias chain は古い挙動にしか依存していないので失敗しにくいと考えるが、3.3 の `replace_require` の実装差、Zeitwerk 2.6 の core_ext、`caller_locations` の `absolute_path` が realpath を返すかは、§8.4 のマトリクスで最初に確認する。
2. **`Kernel.prepend` が遅くなる原因は特定していない。** 「prepend しない」で回避したが、H4〜H9 の prepend（Kernel 以外）が同じ性質を持たないかは計測で確認する。プロトタイプ全体では +1.4% だったので、現状は問題ない。
3. **`define_method :require` で（alias せずに）上書きするライブラリ。** フックが外れて計測が欠ける。boot は失敗しない。§1.3 の検出ロジックで警告を出す。実在するかは gem コーパス（上位 1000 gem）を grep して調べる。
4. **H4〜H9 の対象メソッドを alias chain するライブラリ。** prepend 本体が複製されて `super` が失敗する、という同じ種類の問題が起こりうる。現時点では見つかっていないが、3 と同じく調査する。保険として、Rails 関連のフックだけを無効にする環境変数（`HAYAOKI_PROBE_HOOKS=require`）を用意する。
5. **Rails のメソッドシグネチャの変化。** `execute_hook(name, base, options, block)` と `Initializer#run(*args)` は 7.0〜8.1 で同じことを 8.1 のソースで確認したが、7.0 のソースではまだ確認していない。フックの引数を `(...)` で受けて、内部の参照を最小にすることでも防ぐ。
6. **事実2の `Bundler::GemNotFound` の根本原因は未特定。** 本設計では `gem_original_require` に委譲するので発生しないが、`--disable-gems` で後から RubyGems が読み込まれる方法などで再発しないか、8.2 の4番で確認する。
7. **時間の帰属の限界。** bootsnap と Zeitwerk のラッパー処理、Zeitwerk の `on_load` コールバック、スレッドの並行実行の時間は、親 span の self time に入る。レポートで注記する。
8. **大規模アプリでのペイロードとメモリ。** require が数万件の場合の JSON サイズと at_exit の時間を測り、必要なら §4.2 の文字列表方式（v2）に移る。
9. **`exit!` と `exec` を使う構成では結果が出ない。** P2 の H10 で `exit!` は救えるが、`exec` には対応できない。親のエラーメッセージで案内する。

---

## 付録 A. 実験の記録（Ruby 4.0.6 / Rails 8.1.4 / bootsnap 1.26.1 / Zeitwerk 2.8.3、RAILS_ENV=production、eager_load=true）

### A-1. alias と prepend の意味論（`spike/04_alias/01_alias_semantics.rb`）

| 対象 / 方式 | super | callee ガード |
|---|---|---|
| instance | `no superclass method` | 成功 |
| singleton | 無限に再帰 | 成功 |

callee ガードはこの最小再現では成功するが、実アプリでは A-2 のとおり下位のラッパーを呼ばれない。

### A-2. 実アプリでの方式比較（`spike/04_alias/run_variants.sh`、fixture は `setup_app.sh`）

| 方式 | 結果 | bootsnap / Zeitwerk / bundled_gems の呼出回数 | boot（warm、5回の平均） |
|---|---|---|---|
| none | 成功 | - | 664ms |
| naive | GemRequireError（singleton の `super`） | - | - |
| bindcall | 暗黙の名前空間で LoadError（`app/models/admin` を require） | 0 / 0 / 0 | 728ms（暗黙の名前空間を追加する前） |
| callee | 同上 | 0 / 0 / 2 | 734ms（同上） |
| runtime | GemRequireError（bundled_gems の交差による） | - | - |
| chain | 成功、警告も残る | 1414 / 649 / 705 | 672ms |

### A-3. オーバーヘッドの要因の切り分け（中央値）

| 構成 | boot | none との差 |
|---|---|---|
| none | 671ms | - |
| プロトタイプ（require_relative を Kernel に prepend） | 754ms | +12% |
| require_relative のフックなし | 675ms | +0.6% |
| require_relative を定義しない空の Kernel prepend | 735ms | +9.5% |
| `Kernel.prepend(Module.new)` だけ（bootsnap あり） | 712ms | +3.5%（none は 688ms） |
| 同上（`DISABLE_BOOTSNAP_LOAD_PATH_CACHE=1`） | 749ms | 差なし（none は 753ms） |
| 同上（bootsnap なし） | 796ms | 差なし（none は 792ms） |
| **最終版のプロトタイプ（prepend なし、JSON 書き出し込み）** | **675ms** | **+1.4%**（p90 +0.9%） |
| 最終版のプロトタイプ（bootsnap なし） | 799ms | +1.3% |

### A-4. 実際の require チェーン（最終版のプロトタイプ、boot 後に取得したスタック）

```
instance:  zeitwerk Kernel#require → bootsnap Kernel#require → bundled_gems(instance)
           → Kernel.no_warning_require (= probe singleton wrapper) → builtin
singleton: zeitwerk Kernel.require → bundled_gems(singleton)
           → Kernel#no_warning_require (= probe instance wrapper) → RubyGems require → builtin
```

### A-5. プロトタイプの出力（`spike/04_probe/analyze.rb`）

- slowgem: total 196ms、self 105.3ms / inner（require_relative）55.2ms / other 35.6ms（期待値は 100 / 50 / 30）
- on_load(action_controller) 45.0ms（期待値 40）、持ち主は `slowgem.rb:4`
- VM の起動時間の推定: realtime の差 28.2ms、probe 以前の CPU 時間 26.9ms
- `false` を返した require: 907 件、合計 5.1ms（0.7%）
- edge（`spike/04_probe/edge/run_edge.sh`）: スレッドの span は別の根になる / 例外は raised として残る / boot 失敗時は status=error で部分結果を返す / `exit!` では出力なし / `--disable-gems` で動く / fork した子は書かない / 二重読み込みでも動く
