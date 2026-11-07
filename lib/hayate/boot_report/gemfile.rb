# frozen_string_literal: true

module Hayate
  module BootReport
    # Gemfile の行ベースの簡易パーサ (eval しない)。
    # group ブロック / インラインの group: groups: / require: を拾う。
    module Gemfile
      # groups: 空配列 = どの group にも属さない (production で読み込まれる)
      # require: nil (指定なし) / false / 文字列の配列 (別名で require される)
      Entry = Struct.new(:name, :groups, :require, keyword_init: true)

      GEM_RE = /\A\s*gem\s*\(?\s*["']([^"']+)["']/
      GROUP_BLOCK_RE = /\A\s*group\s*\(?\s*([^#]*?)\)?\s+do\b/
      DO_BLOCK_RE = /\bdo\s*(\|[^|]*\|)?\s*\z/
      END_RE = /\A\s*end\b/

      module_function

      # => { "gem-name" => Entry }
      def parse(src)
        entries = {}
        stack = [] # 各要素: group 名の配列 (group ブロック) か nil (その他の do ブロック)
        src.each_line do |raw|
          line = raw.sub(/(?<!["'\w])#.*/, "")
          if (m = line.match(GROUP_BLOCK_RE))
            stack.push(symbols(m[1]))
          elsif line.match?(END_RE)
            stack.pop
          elsif (m = line.match(GEM_RE))
            groups = stack.compact.flatten + inline_groups(line)
            entries[m[1]] = Entry.new(name: m[1], groups: groups.uniq, require: require_opt(line))
          elsif line.match?(DO_BLOCK_RE)
            stack.push(nil)
          end
        end
        entries
      end

      def symbols(str)
        str.scan(/:(\w+)|["'](\w+)["']/).map { |a, b| a || b }
      end

      def inline_groups(line)
        m = line.match(/(?:\bgroups?:|:groups?\s*=>)\s*(\[[^\]]*\]|:\w+|["']\w+["'])/)
        m ? symbols(m[1]) : []
      end

      def require_opt(line)
        m = line.match(/(?:\brequire:|:require\s*=>)\s*(false|nil|true|\[[^\]]*\]|"[^"]*"|'[^']*')/)
        return nil unless m
        v = m[1]
        return false if v == "false"
        return nil if v == "nil" || v == "true"
        v.scan(/["']([^"']*)["']/).flatten
      end
    end
  end
end
