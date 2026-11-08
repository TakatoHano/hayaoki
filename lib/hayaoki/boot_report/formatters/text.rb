# frozen_string_literal: true

require_relative "../advisor"

module Hayaoki
  module BootReport
    module Formatters
      # 端末向けテキスト。reports は { "warm" => Report, "cold" => Report } (aggregate_result の戻り値)。
      class Text
        WIDTH = 80
        BAR = "█"
        BAR_WIDTH = 28
        PHASE_LABELS = { "vm_boot" => "vm boot", "bundler_require" => "bundler require", "initialize" => "initialize",
                         "eager_load" => "eager load", "boot" => "boot" }.freeze

        # redact: 文字列を受け取って伏せた文字列を返すもの (--redact)。切り詰める前に適用しないとパスが一致しない。
        def initialize(top: 10, redact: nil)
          @top = top
          @redact = redact
        end

        # Advisor の結果 (Suggestion の配列 / 警告の配列)。nil なら Suggestions の節を出さない。
        attr_accessor :suggestions, :suggestion_warnings

        def with_suggestions(list, warnings = [])
          @suggestions = list
          @suggestion_warnings = warnings
          self
        end

        def format(reports)
          reports = { reports.condition.to_s => reports } unless reports.is_a?(Hash)
          @conds = reports.keys
          @reports = reports
          out = []
          header(out)
          phases(out)
          categories(out)
          ranked(out, "Top gems (self time)", :gems, ->(r) { r.gems }, ->(e) { e["name"] }, "self_ms", breakdown: { "req" => "require_ms", "onload" => "on_load_ms", "eager" => "eager_ms" })
          ranked(out, "Top initializers (inclusive)", :inits, ->(r) { r.initializers }, ->(e) { [e["name"], e["context"]].compact.join(" ") }, "inclusive_ms",
                 breakdown: { "init body (own time, not blamed on gem)" => "init_body_ms" })
          ranked(out, "Top on_load hooks (inclusive)", :on_loads, ->(r) { r.on_loads }, ->(e) { [e["name"], e["source"]].compact.join(" ") }, "inclusive_ms")
          if @reports.values.any? { |r| Array(r.eager_namespaces).any? }
            ranked(out, "Top eager_load namespaces (inclusive)", :eager_namespaces, ->(r) { r.eager_namespaces }, ->(e) { e["name"] }, "inclusive_ms")
          end
          false_requires(out)
          overhead(out)
          warnings(out)
          suggestions_section(out)
          out.map { |l| clip(l) }.join("\n") + "\n"
        end

        private

        def header(out)
          m = (@reports.values.first.meta || {})
          out << "hayaoki boot-report"
          out << "  app: #{m["app_dir"]}" if m["app_dir"]
          out << "  runs=#{m["runs"] || @reports.values.first.runs} env=#{m["env"]} bootsnap=#{m["bootsnap"] || @conds.join(",")}"
          @reports.each do |c, r|
            failed = r.failed.to_i.positive? ? "  (#{r.failed} failed)" : ""
            out << "  total[#{c}]: #{stat_s(r.phases["total"])}#{failed}"
          end
          out << "  diff (#{@conds.last} - #{@conds.first}): #{diff_s(med(first_total), med(last_total))}" if @conds.size > 1
          out << ""
        end

        def first_total = @reports[@conds.first].phases["total"]
        def last_total = @reports[@conds.last].phases["total"]

        def phases(out)
          out << "Phases (median)"
          keys = PHASE_LABELS.keys.select { |k| @reports.values.any? { |r| r.phases[k] } }
          max = keys.flat_map { |k| @reports.values.map { |r| med(r.phases[k]) } }.compact.max.to_f
          keys.each do |k|
            @reports.each do |c, r|
              s = r.phases[k]
              next unless s
              label = @conds.size > 1 ? "#{PHASE_LABELS[k]} [#{c}]" : PHASE_LABELS[k]
              label = "  └ #{label}" if k == "eager_load" # initialize の内側 (足し算しない)
              n = max.positive? ? (med(s) / max * BAR_WIDTH).round : 0
              n = 1 if n.zero? && med(s).to_f.positive?
              out << Kernel.format("  %-22s %-#{BAR_WIDTH}s %s", label, BAR * n, stat_s(s, range: @conds.size == 1))
            end
          end
          out << "  (└ eager load runs within initialize; do not add them)" if keys.include?("eager_load")
          out << ""
        end

        def categories(out)
          return if @reports.values.all? { |r| (r.categories || {}).empty? }
          out << "Self time by category (median; boot - attributed = unattributed)"
          @reports.each do |c, r|
            cats = r.categories || {}
            next if cats.empty?
            tag = @conds.size > 1 ? " [#{c}]" : ""
            cats.each { |k, v| out << Kernel.format("  %-22s %10s", "#{k}#{tag}", "#{fmt(med(v["self_ms"]))}") }
          end
          out << ""
        end

        def ranked(out, title, _key, getter, namer, metric, breakdown: nil)
          out << "#{title} (top #{@top})"
          lists = @reports.transform_values { |r| Array(getter.call(r)) }
          names = lists.values.first.first(@top).map(&namer)
          if @conds.size > 1
            names |= lists.values.last.first(@top).map(&namer)
            names = names.first(@top * 2)
          end
          if names.empty?
            out << "  (none)"
            out << ""
            return
          end
          idx = lists.transform_values { |l| l.to_h { |e| [namer.call(e), e] } }
          nw = [WIDTH - 2 - 12 * @conds.size - (@conds.size > 1 ? 10 : 22), 20].max
          names.each do |n|
            vals = @conds.map { |c| idx[c][n] && idx[c][n][metric] }
            line = Kernel.format("  %-#{nw}s", trunc(n.to_s, nw))
            vals.each { |v| line += Kernel.format(" %10s", v ? "#{fmt(med(v))}" : "-") }
            if @conds.size > 1
              line += Kernel.format(" %9s", vals.all? ? signed(med(vals.last) - med(vals.first)) : "-")
            else
              v = vals.first
              line += Kernel.format(" %-20s", v ? "[#{fmt(v["min"])}-#{fmt(v["max"])}]" : "")
              e = idx[@conds.first][n]
              if breakdown && e
                out << line.rstrip
                parts = breakdown.filter_map do |l, kk|
                  x = e[kk] && med(e[kk])
                  "#{l} #{fmt(x)}" if x && x >= 0.05
                end
                next if parts.empty?
                cat = e["category"] ? "#{e["category"]}: " : ""
                out << "      #{cat}#{parts.join(", ")}".rstrip
                next
              end
            end
            out << line.rstrip
          end
          out << "  (ms, median)" if @conds.size > 1
          out << ""
        end

        def false_requires(out)
          out << "require that returned false"
          @reports.each do |c, r|
            f = r.false_require || {}
            tag = @conds.size > 1 ? " [#{c}]" : ""
            out << "  count#{tag}: #{f["count"] ? fmt(med(f["count"]), 0) : "-"}, time: #{stat_s(f["time_ms"])}"
          end
          out << ""
        end

        def overhead(out)
          out << "Measurement overhead"
          ov = (@reports.values.first.meta || {})["overhead"] || {}
          @conds.each do |c|
            o = ov[c]
            next out << "  #{c}: n/a" unless o
            ratio = o["ratio"] ? Kernel.format(", x%.3f", o["ratio"]) : ""
            noise = overhead_noise(o)
            diff = if noise && o["diff_ms"].abs < noise
                     "diff within noise (±#{fmt(noise)} ms) (#{signed(o["diff_ms"])} ms#{ratio})"
                   else
                     "diff #{signed(o["diff_ms"])} ms#{ratio.empty? ? "" : " (#{ratio[2..]})"}"
                   end
            out << "  #{c}: baseline #{fmt(o["baseline_ms"])} ms, with probe #{fmt(o["probe_ms"])} ms"
            out << "    #{diff}"
          end
          out << ""
        end

        # 基準側と probe 側の run ごとのばらつき (min〜max の半幅) の大きい方。サンプルが 2 件未満なら nil。
        def overhead_noise(o)
          halves = %w[baseline_samples_ms probe_samples_ms].filter_map do |k|
            v = Array(o[k]).compact
            (v.max - v.min) / 2.0 if v.size >= 2
          end
          halves.max
        end

        def warnings(out)
          w = @reports.values.flat_map { |r| Array(r.warnings) }.uniq
          return if w.empty?
          out << "Warnings"
          w.each { |x| out << "  ! #{x}" }
        end

        SUGGESTION_ORDER = %w[high medium low info].freeze

        def suggestions_section(out)
          return unless @suggestions
          out << ""
          out << "Suggestions"
          if @suggestions.empty?
            out << "  (none)"
          end
          sorted = @suggestions.each_with_index.sort_by { |s, i| [SUGGESTION_ORDER.index(s.confidence.to_s) || 9, i] }.map(&:first)
          sorted.each do |s|
            wrap("[#{s.confidence}] #{s.title}", 2, 9).each { |l| out << l }
            wrap("id: #{s.id}", 9, 11).each { |l| out << l } if s.id
            ev = Array(s.evidence)
            ev.first(5).each { |e| wrap("- #{evidence_s(e)}", 9, 11).each { |l| out << l } }
            out << "         - (+#{ev.size - 5} more)" if ev.size > 5
            out << "         estimated savings: up to #{fmt(s.estimated_savings_ms)} ms" if s.estimated_savings_ms
            wrap("overlaps with: #{s.overlaps.join(", ")} (savings not additive)", 9, 11).each { |l| out << l } unless Array(s.overlaps).empty?
            out << "         action:"
            s.action.to_s.split("\n").each do |line|
              lead = line[/\A */].size
              wrap(line.strip, 11 + lead, 13 + lead).each { |l| out << l }
            end
          end
          ub = Suggestion.savings_upper_bound(@suggestions)
          if ub && @suggestions.count(&:estimated_savings_ms) > 1
            wrap("total savings: at most #{fmt(ub)} ms (upper bound; findings overlap, so do not treat as additive)", 2, 4).each { |l| out << l }
          end
          Array(@suggestion_warnings).each { |w| wrap("! #{w}", 2, 4).each { |l| out << l } }
        end

        def evidence_s(e)
          e.is_a?(Hash) ? e.map { |k, v| "#{k}=#{v.is_a?(Array) ? v.join("/") : v}" }.join(" ") : e.to_s
        end

        # 80 桁に収まるように単語で折り返す。1 行目は indent、続きは cont 桁で字下げする。
        def wrap(text, indent, cont)
          lines = []
          cur = " " * indent
          fresh = true
          text.to_s.split(/\s+/).reject(&:empty?).each do |w|
            w = w[0, WIDTH - cont - 2] + "…" if w.length > WIDTH - cont - 1
            if !fresh && cur.length + 1 + w.length > WIDTH - 1
              lines << cur
              cur = " " * cont
              fresh = true
            end
            cur += (fresh ? "" : " ") + w
            fresh = false
          end
          lines << cur
        end

        def med(s) = s.is_a?(Hash) ? s["median"] : s

        def fmt(x, digits = 1)
          x.nil? ? "-" : Kernel.format("%.#{digits}f", x)
        end

        def signed(x) = Kernel.format("%+.1f", x)

        def diff_s(a, b)
          return "-" unless a && b
          pct = a.positive? ? Kernel.format(" (%+.1f%%)", (b - a) / a * 100) : ""
          "#{signed(b - a)} ms#{pct}"
        end

        def stat_s(s, range: true)
          return "-" unless s
          base = "#{fmt(s["median"])} ms"
          range ? "#{base} [#{fmt(s["min"])}-#{fmt(s["max"])}]" : base
        end

        def trunc(s, w)
          s = @redact.call(s) if @redact
          s.length > w ? "…#{s[-(w - 1)..]}" : s
        end

        def clip(l)
          l = @redact.call(l) if @redact
          l.length > WIDTH ? l[0, WIDTH - 1] + "…" : l
        end
      end
    end
  end
end
