# frozen_string_literal: true

require_relative "report"

module Hayate
  module BootReport
    # probe の payload (Runner が集めた複数回分) を、設計書 §3.4 の正規化をかけた木にして集計する。
    # 時間はすべて ms。各指標は { "median", "min", "max" } (偶数個なら中央2つの平均)。
    class Aggregator
      K_REQ = 0; K_RR = 1; K_LOAD = 2; K_INIT = 3; K_ONLOAD = 4; K_HOOKS = 5; K_EAGER = 6; K_PHASE = 7

      Span = Struct.new(:idx, :kind, :name, :parent, :t0, :t1, :res, :tid, :cpu, :children, :incomplete, :merged, :owner) do
        def require_kind? = kind <= K_LOAD
        def dur_us = t1 - t0
        def raised? = res == "raised"
        # require 系は feature (res)。raised や非 String は nil
        def feature = require_kind? && res.is_a?(String) && !raised? ? res : nil
      end

      Owner = Struct.new(:category, :name) # category: "gem" / "app" / "stdlib" / "other"

      def initialize(top_files: 30, top_initializers: 30, top_on_loads: 30)
        @top_files = top_files
        @top_initializers = top_initializers
        @top_on_loads = top_on_loads
      end

      # RunResult → { condition(String) => Report }
      def aggregate_result(result)
        result.payloads.to_h do |cond, list|
          [cond, aggregate(list, condition: cond, meta: result.meta)]
        end
      end

      def aggregate(payloads, condition: nil, meta: {})
        ok, bad = payloads.partition { |p| p["status"] == "ok" }
        warnings = Array(meta["warnings"]).dup
        warnings << "#{bad.size} failed run(s) excluded from aggregation" unless bad.empty?
        warnings.concat(ok.flat_map { |p| Array(p["probe_warnings"]) + Array(p["probe_errors"]).map { |e| "probe error: #{e}" } }.uniq)
        analyses = ok.map { |p| analyze(p) }
        thread_spans = analyses.map { |a| a[:background_spans] }.max.to_i
        warnings << "#{thread_spans} span(s) recorded on background threads; attribution is approximate and they are excluded from totals" if thread_spans.positive?
        merged = analyses.sum { |a| a[:merged] }

        Report.new(
          condition: condition, runs: ok.size, failed: bad.size,
          ruby: ok.first && ok.first["ruby"], features: stat(analyses.map { |a| a[:features] }),
          phases: phases(analyses),
          categories: keyed_stats(analyses.map { |a| a[:categories] }, order_by: "self_ms"),
          gems: gems(analyses),
          files: files(analyses),
          initializers: initializers(analyses),
          app_initializer_times: app_initializer_times(analyses),
          on_loads: on_loads(analyses),
          false_require: {
            "count" => stat(analyses.map { |a| a[:false_count] }), "time_ms" => stat(analyses.map { |a| a[:false_ms] })
          },
          threads: { "background_spans" => thread_spans, "merged_duplicates" => merged },
          meta: meta, warnings: warnings.uniq
        )
      end

      # 1 回分の payload を解析する。テストや formatter 用に公開しておく。
      def analyze(payload)
        spans = build_spans(payload)
        merged = normalize!(spans)
        spans = spans.reject(&:merged)
        resolver = OwnerResolver.new(payload)
        main = spans.select { |s| s.tid.to_i == 0 }
        pmap = spans.to_h { |s| [s.idx, s] }
        main.each { |s| s.owner = owner_of(s, resolver) }
        selfs = {}
        spans.each { |s| selfs[s] = s.dur_us - s.children.sum { |c| c.dur_us } }

        a = {
          merged: merged, features: payload["features"], background_spans: spans.size - main.size,
          false_count: payload.dig("false_require", "count").to_i, false_ms: payload.dig("false_require", "time_us").to_i / 1000.0,
          gems: Hash.new { |h, k| h[k] = { "self_ms" => 0.0, "require_ms" => 0.0, "on_load_ms" => 0.0, "eager_ms" => 0.0, "initializer_count" => 0, "category" => nil } },
          categories: Hash.new { |h, k| h[k] = { "self_ms" => 0.0 } },
          files: Hash.new { |h, k| h[k] = { "self_ms" => 0.0, "inclusive_ms" => 0.0, "owner" => nil, "category" => nil, "count" => 0 } },
          initializers: Hash.new { |h, k| h[k] = { "inclusive_ms" => 0.0, "init_body_ms" => 0.0 } },
          on_loads: Hash.new { |h, k| h[k] = { "inclusive_ms" => 0.0, "self_ms" => 0.0 } },
          phase: {}
        }
        spawn_at = payload["spawn_at"]&.to_f
        boot_us = payload["boot_end_us"] || payload["exit_us"]
        a[:phase]["vm_boot"] = (payload["t0_real"] - spawn_at) * 1000.0 if spawn_at && payload["t0_real"]
        a[:phase]["boot"] = boot_us / 1000.0 if boot_us
        a[:phase]["total"] = (a[:phase]["vm_boot"] || 0.0) + boot_us / 1000.0 if boot_us

        main.each do |s|
          self_ms = selfs[s] / 1000.0
          dur_ms = s.dur_us / 1000.0
          o = s.owner
          case s.kind
          when K_REQ, K_RR, K_LOAD
            add_owner(a, o, self_ms, "require_ms")
            f = a[:files][s.feature || s.name.to_s]
            f["self_ms"] += self_ms
            f["inclusive_ms"] += dur_ms
            f["owner"] = o.name
            f["category"] = o.category
            f["count"] += 1
          when K_ONLOAD
            add_owner(a, o, self_ms, "on_load_ms")
            e = a[:on_loads][[s.name, s.res.is_a?(String) ? s.res : nil]]
            e["inclusive_ms"] += dur_ms
            e["self_ms"] += self_ms
            e["owner"] = o.name
            e["category"] = o.category
          when K_INIT
            # initializer 本体の自己時間 (require や子に帰属できない分) は定義元 gem に付けず、init_body_ms として別掲する
            ctx = s.res.is_a?(Array) ? s.res[0] : nil
            e = a[:initializers][[s.name, ctx]]
            e["inclusive_ms"] += dur_ms
            e["init_body_ms"] += self_ms
            a[:categories]["init_body"]["self_ms"] += self_ms
            e["owner"] = o.name
            # 時間は付けないが、initializer を定義していること (= Railtie/Engine) は記録する
            g = a[:gems][o.name]
            g["category"] = o.category
            g["initializer_count"] += 1
            e["category"] = o.category
          when K_PHASE
            key = s.name
            a[:phase][key] = a[:phase][key].to_f + dur_ms if %w[bundler_require initialize].include?(key)
          when K_EAGER
            # eager_load_namespaces の span (meta = 定義位置) は自己時間を持ち主に付ける。Zeitwerk の span は従来どおり。
            add_owner(a, o, self_ms, "eager_ms") if s.res.is_a?(String)
            a[:phase]["eager_load"] = a[:phase]["eager_load"].to_f + dur_ms unless eager_ancestor?(s, pmap)
          end
        end
        # 帰属されなかった時間 (run_load_hooks 自体、phase / eager_load span の自己時間、span の外) を別掲する
        if boot_us
          attributed = a[:categories].values.sum { |c| c["self_ms"] }
          a[:categories]["unattributed"]["self_ms"] = [boot_us / 1000.0 - attributed, 0.0].max
        end
        a
      end

      private

      def stat(values)
        v = values.compact
        return nil if v.empty?
        s = v.sort
        n = s.size
        med = n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
        { "median" => r(med), "min" => r(s.first), "max" => r(s.last) }
      end

      def r(x) = x.is_a?(Float) ? x.round(3) : x

      def phases(analyses)
        keys = %w[vm_boot bundler_require initialize eager_load boot total]
        keys.to_h { |k| [k, stat(analyses.map { |a| a[:phase][k] })] }
      end

      # runs 個の Hash (key => { metric => number, ... }) を key ごとに metric ごとの stat にする。
      # 欠けた run は 0 として扱う。非数値の属性 (owner など) は最初に見つかった値を使う。
      def merge_runs(list)
        keys = list.flat_map(&:keys).uniq
        keys.to_h do |k|
          rows = list.map { |h| h[k] }
          sample = rows.compact.first
          out = {}
          sample.each do |m, v|
            out[m] = v.is_a?(Numeric) ? stat(rows.map { |row| row ? row[m] : 0 }) : v
          end
          [k, out]
        end
      end

      def keyed_stats(list, order_by:)
        merge_runs(list).sort_by { |_, v| -v[order_by]["median"] }.to_h
      end

      def gems(analyses)
        merged = merge_runs(analyses.map { |a| a[:gems].to_h })
        merged.sort_by { |k, v| [-v["self_ms"]["median"], k] }.map { |k, v| { "name" => k }.merge(v) }
      end

      def files(analyses)
        merged = merge_runs(analyses.map { |a| a[:files].to_h })
        merged.sort_by { |k, v| [-v["self_ms"]["median"], k] }.first(@top_files).map { |k, v| { "path" => k }.merge(v) }
      end

      def initializers(analyses)
        merged = merge_runs(analyses.map { |a| a[:initializers].to_h })
        merged.sort_by { |k, v| [-v["inclusive_ms"]["median"], k.to_s] }.first(@top_initializers).map do |(name, ctx), v|
          { "name" => name, "context" => ctx }.merge(v)
        end
      end

      # Advisor (heavy_app_initializer) 用。表示用の top-N 切り詰めをかけない app 側の inclusive 時間。
      def app_initializer_times(analyses)
        inits = merge_runs(analyses.map { |a| a[:initializers].to_h }).select { |_, v| v["category"] == "app" }
        files = merge_runs(analyses.map { |a| a[:files].to_h }).select { |k, v| v["category"] == "app" && k.include?("/config/initializers/") }
        {
          "initializers" => inits.map { |(name, ctx), v| { "name" => name, "context" => ctx, "category" => "app", "inclusive_ms" => v["inclusive_ms"] } },
          "files" => files.map { |k, v| { "path" => k, "category" => "app", "inclusive_ms" => v["inclusive_ms"] } }
        }
      end

      def on_loads(analyses)
        merged = merge_runs(analyses.map { |a| a[:on_loads].to_h })
        merged.sort_by { |k, v| [-v["inclusive_ms"]["median"], k.to_s] }.first(@top_on_loads).map do |(name, loc), v|
          { "name" => name, "source" => loc }.merge(v)
        end
      end

      def add_owner(a, owner, self_ms, kind_key)
        # app / stdlib / other も gems の表に並べる (ランキングで比較できるように)
        g = a[:gems][owner.name]
        g["category"] = owner.category
        g["self_ms"] += self_ms
        g[kind_key] += self_ms
        a[:categories][owner.category]["self_ms"] += self_ms
      end

      # 入れ子の eager_load (eager_load_all が各 loader の eager_load を呼ぶ形) を二重に数えない
      def eager_ancestor?(s, pmap)
        while (s = pmap[s.parent])
          return true if s.kind == K_EAGER
        end
        false
      end

      # --- 木の構築 -----------------------------------------------------------

      def build_spans(payload)
        w = payload["width"] || 8
        ev = payload["events"] || []
        exit_us = payload["exit_us"] || ev.each_slice(w).filter_map { |e| e[4] }.max || 0
        spans = []
        by_idx = {}
        (0...(ev.size / w)).each do |i|
          kind, name, par, t0, t1, res, tid, cpu = ev[i * w, w]
          incomplete = t1.nil?
          s = Span.new(i * w, kind, name, par, t0, t1 || [exit_us, t0].max, res, tid, cpu, [], incomplete, false, nil)
          spans << s
          by_idx[s.idx] = s
        end
        spans.each do |s|
          p = by_idx[s.parent]
          p.children << s if p
        end
        spans
      end

      # §3.4: 唯一の子が同じ feature の require 系なら 1 つにまとめる。まとめた件数を返す。
      def normalize!(spans)
        count = 0
        spans.each do |s|
          next if s.merged
          while s.require_kind? && s.feature && s.children.size == 1
            c = s.children.first
            break unless c.require_kind? && c.feature == s.feature && c.tid == s.tid
            c.merged = true
            s.children = c.children
            s.children.each { |g| g.parent = s.idx }
            count += 1
          end
        end
        # 外側から順に処理するので、親が先に処理される (EV は先行順)
        count
      end

      # --- 帰属 ---------------------------------------------------------------

      def owner_of(s, resolver)
        case s.kind
        when K_REQ, K_RR, K_LOAD
          path = s.feature || (s.name.to_s.start_with?("/") ? s.name.to_s : nil)
          path ? resolver.owner(path) : Owner.new("other", "other")
        when K_ONLOAD
          loc = s.res.is_a?(String) ? s.res.sub(/:\d+\z/, "") : nil
          loc ? resolver.owner(loc) : Owner.new("other", "other")
        when K_EAGER
          s.res.is_a?(String) ? resolver.owner(s.res.sub(/:\d+\z/, "")) : Owner.new("other", "other")
        when K_INIT
          loc = s.res.is_a?(Array) && s.res[1].is_a?(String) ? s.res[1].sub(/:\d+\z/, "") : nil
          loc ? resolver.owner(loc) : Owner.new("other", "other")
        else
          Owner.new("other", "other")
        end
      end

      # specs / rails_root / libdir から、パスの持ち主を最長前方一致で引く。
      class OwnerResolver
        def initialize(payload)
          @pwd = payload["pwd_realpath"]
          @cache = {}
          @real = {}
          gem_prefixes = []
          (payload["specs"] || {}).each do |name, (_ver, path, ext)|
            [path, ext].compact.each { |pth| prefixes(pth).each { |pf| gem_prefixes << [pf, name] } }
          end
          @gems = gem_prefixes.uniq.sort_by { |pf, _| -pf.size }
          root = payload["rails_root"] || @pwd
          @app = root && prefixes(root)
          # アプリ自身が gem (gemspec / path: "." / engine の dummy app) のとき、gem の prefix がアプリ root を含んでしまう。
          # その場合は app/config/lib/db 配下を gem より先に app とみなす。
          @app_dirs = nil
          if @app && @gems.any? { |pf, _| @app.any? { |a| under?(a, pf) } }
            @app_dirs = @app.flat_map { |a| %w[app config lib db].map { |d| File.join(a, d) } }
          end
          @stdlib = Array(payload["libdir"]).flat_map { |d| prefixes(d) }.uniq
        end

        def owner(path)
          path = File.expand_path(path, @pwd || Dir.pwd) unless path.start_with?("/")
          dir = File.dirname(path)
          @cache[dir] ||= resolve_dir(dir)
        end

        private

        def prefixes(path)
          [path, realpath(path)].compact.uniq
        end

        def realpath(path)
          @real[path] ||= begin
            File.realpath(path)
          rescue SystemCallError
            path
          end
        end

        def under?(dir, prefix) = dir == prefix || dir.start_with?(prefix.end_with?("/") ? prefix : "#{prefix}/")

        def resolve_dir(dir)
          dirs = [dir, realpath(dir)].uniq
          return Owner.new("app", "app") if @app_dirs&.any? { |pf| dirs.any? { |d| under?(d, pf) } }
          # 最長一致: gem の full_gem_path / extension_dir
          hit = @gems.find { |pf, _| dirs.any? { |d| under?(d, pf) } }
          return Owner.new("gem", hit[1]) if hit
          return Owner.new("app", "app") if @app&.any? { |pf| dirs.any? { |d| under?(d, pf) } }
          return Owner.new("stdlib", "stdlib") if @stdlib.any? { |pf| dirs.any? { |d| under?(d, pf) } }
          Owner.new("other", "other")
        end
      end
    end
  end
end
