# 技術スパイク記録

hayate boot-report は Rails の boot 時間を計測するツールである。計測の中核となる probe は、Kernel に require / require_relative / load を prepend し、`ruby -r probe.rb` で bundler より先に読み込む方式を取る。本ドキュメントは、この方式が実際に成立するかを確かめるために行った技術スパイクの記録である。

## スパイク1: require 直後の $LOADED_FEATURES.last で読み込んだファイルを特定できるか（spike/01_loaded_features.rb）

### 問い

require が true を返した直後の `$LOADED_FEATURES.last` から、今読み込まれたファイルを特定できるか。

### 結果

できる。ネストした require、循環 require、C拡張（json の .bundle）、autoload、Kernel.require、load のいずれでも、true を返した直後の $LOADED_FEATURES.last が自分自身と一致した（Ruby は親を子より後に追加する）。autoload は Kernel#require を経由する。例外で抜けた require は $LOADED_FEATURES に追加されない（スタックの巻き戻しは必要）。

### 発見した落とし穴

- require_relative を prepend で包んで super を呼ぶと、相対パスの基準が probe ファイルになり LoadError になる。対策として、caller_locations で呼び出し元の絶対パスを解決してから委譲する。
- 委譲すると require_relative と内側の require が二重記録されうる。

### 設計への反映

- require_relative の相対パスは caller_locations で呼び出し元の絶対パスに解決してから委譲する。
- 記録の重複が起きうるため、記録側で重複排除を行う前提とする。

### 最終設計での扱い

- require_relative は prepend せず Kernel に直接定義し直す。二重記録は probe.md §3.4 で扱う（§1.4）。

### スクリプト

- spike/01_loaded_features.rb

## スパイク2: bootsnap / Zeitwerk と共存できるか（spike/02_probe.rb, spike/02_run.sh）

Rails 8.1.4.1 / bootsnap 1.26.1 / Zeitwerk 2.8.3、RAILS_ENV=production で検証した。

### 問い

bootsnap および Zeitwerk が有効な Rails アプリの起動を壊さず、probe で読み込みを捕捉できるか。また、probe を読み込む順序によって結果が変わるか。

### 結果

| パターン | 起動 | カバレッジ | app/ 捕捉 |
| --- | --- | --- | --- |
| A: bootsnap あり・probe を -r で先に | 成功 | 1100/1164 = 94.5% | 5/5 |
| B: bootsnap あり・probe を後から | 成功 | 927/1164 = 79.6% | 5/5 |
| C: bootsnap なし・probe を先に | 成功 | 1070/1132 = 94.5% | 5/5 |
| D: bootsnap あり（warm cache）・probe を先に | 成功 | 1100/1162 = 94.7% | 5/5 |

- $LOADED_FEATURES.last の一致率は全パターンで 100%、重複記録は 0 件だった。
- bootsnap による取りこぼしはなかった。Zeitwerk の autoload も捕捉できた。
- 未捕捉（probe より前の RubyGems 初期化分）は 57 件。B では bundler・bootsnap を含め 228 件。
- probe 読み込み後の未捕捉は各パターン 5〜9 件。C拡張が内部で rb_require を直接呼んだと推測しているが、未確認である。

### 発見した落とし穴

1. require_relative を require に委譲すると、-r で先に読むパターンで Bundler::GemNotFound により boot が失敗した。gem_original_require に委譲することで解消した。根本原因は未特定である。
2. Ruby 4.0 の bundled_gems.rb は replace_require で Kernel.require（singleton）を alias_method :no_warning_require で退避する。このとき probe のフックごと退避されるため、super が "no superclass method 'require'" で失敗する。Bundler.require は Kernel.require を使うため、boot が失敗する。暫定対策として、probe 読み込み時に元メソッドを保存し bind_call で呼ぶ。副作用として、bundled gem の警告が出なくなり、後続の上書きを無視する。

### 設計への反映

- probe は `-r` で先に読み込むことを必須とする。
- require_relative は gem_original_require に委譲する（落とし穴1への対策）。
- Kernel.require は元メソッドを保存して bind_call で呼ぶ暫定対策を採る（落とし穴2への対策。中核設計で再検討する）。

### 最終設計での扱い

- Kernel への prepend はやめて alias chain にした（probe.md §1.3）。
- bind_call の暫定策は廃止した。bootsnap と Zeitwerk の require ラッパーを素通りしてしまうためである（probe.md §1.2）。

### スクリプト

- spike/02_probe.rb
- spike/02_run.sh

## スパイク3: probe のオーバーヘッドは5%未満か（spike/03_probe.rb, spike/03_bench.rb）

対象は `ruby -e 'require "rails/all"'`、Bundler なし、require 1454 件。15 回× 3 条件で計測し、中央値を用いた。

### 問い

probe を有効にしたときの boot 時間増加は 5% 未満に収まるか。

### 結果

修正前（require_relative を require に委譲した場合）:

| 条件 | 中央値 |
| --- | --- |
| probe なし | 330.7ms |
| 記録あり | 473.9ms（+43.3%） |
| フックのみ | 478.8ms（+44.8%） |

切り分け（最小値、7 回）:

| 条件 | 最小値 |
| --- | --- |
| なし | 344ms |
| require の prepend のみ | 351ms（約 +2%） |
| require_relative の書き換えのみ | 498ms（+45%） |

修正後（require_relative を gem_original_require に委譲した場合）:

| 条件 | 中央値 |
| --- | --- |
| probe なし | 330.3ms |
| 記録あり | 335.7ms（+1.6%、p90 +2.8%） |
| フックのみ | 333.4ms（+0.9%） |

修正後はオーバーヘッドが 5% 未満に収まった。

### 発見した落とし穴

- require_relative を require に委譲すると、本来 require_relative が通らない RubyGems の require を毎回経由することになり、遅くなった。gem の探索が重いことが原因と推測している（未検証）。

### 設計への反映

- require_relative は gem_original_require に委譲する。元メソッドがない場合は require にフォールバックする。
- probe 自身は json 等を読み込まない。アプリの読み込み時間が計測から消えるのを防ぐためである。
- 記録の書き出し時に json 等を遅延 require する。

### 最終設計での扱い

- JSON は自前のエンコーダで出力し、json は require しない（probe.md §5.4）。

### スクリプト

- spike/03_probe.rb
- spike/03_bench.rb

## 未解決事項

- Kernel.require（singleton）の扱い。元メソッドの bind_call は暫定である。代案として、Kernel.require をフックせず Bundler::Runtime#require を包んで gem 単位で計測する案がある。中核設計で決定する。
- Bundler を使う実アプリでのオーバーヘッドの再計測（スパイク3は Bundler なしで計測した）。
- require_relative から require へ委譲すると GemNotFound になる根本原因。
- 未捕捉 5〜9 件の正体。
