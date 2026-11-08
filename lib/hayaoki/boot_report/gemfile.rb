# frozen_string_literal: true

require "set"

module Hayaoki
  module BootReport
    # Gemfile の行ベースの簡易パーサ (eval しない)。
    # group ブロック / インラインの group: groups: / require: / eval_gemfile を拾う。
    module Gemfile
      # groups: 空配列 = どの group にも属さない (production で読み込まれる)
      # require: nil (指定なし) / false / 文字列の配列 (別名で require される)
      Entry = Struct.new(:name, :groups, :require, keyword_init: true)

      GEM_RE = /\A\s*gem\s*\(?\s*["']([^"']+)["']/
      GROUP_BLOCK_RE = /\A\s*group\s*\(?\s*([^#]*?)\)?\s+do\b/
      GROUP_ONELINE_RE = /\A\s*group\s*\(?\s*([^#]*?)\)?\s+do\b(.*)\bend\s*\z/
      DO_BLOCK_RE = /\bdo\s*(\|[^|]*\|)?\s*\z/
      END_RE = /\A\s*end\b/
      # 文のかたち (modifier の `gem "x" if foo` は行頭が gem なのでここには来ない)
      STATEMENT_RE = /\A\s*(?:if|unless|case|while|until|begin|def|class|module|for)\b/
      EVAL_RE = /\beval_gemfile\s*\(?\s*(?:["']([^"']+)["']|\w+)/
      GLOB_RE = /Dir(?:\.glob\s*\(?|\s*\[)\s*(?:[\w.:]*expand_path\s*\(\s*)?["']([^"']+)["']/
      PERCENT_RE = /%[iIwW][\[(]([^\])]*)[\])]/
      MAX_DEPTH = 8

      module_function

      # dir: eval_gemfile の相対パスの基準 (Gemfile のあるディレクトリ)。nil なら eval_gemfile は無視する。
      # => { "gem-name" => Entry }
      def parse(src, dir: nil)
        entries = {}
        walk(src, dir, entries, [], Set.new, 0)
        entries
      end

      def walk(src, dir, entries, base_groups, seen, depth)
        stack = [base_groups] # 各要素: group 名の配列 (group ブロック) か nil (その他のブロック)
        glob = nil
        logical_lines(src).each do |line|
          if (m = line.match(GROUP_ONELINE_RE))
            add_gem(entries, m[2], stack.compact.flatten + symbols(m[1]))
          elsif (m = line.match(GROUP_BLOCK_RE))
            stack.push(symbols(m[1]))
          elsif line.match?(END_RE)
            stack.pop if stack.size > 1
          elsif line.match?(GEM_RE)
            add_gem(entries, line, stack.compact.flatten)
          elsif line.match?(EVAL_RE)
            glob = line[GLOB_RE, 1] || glob
            eval_files(line, glob, dir).each do |path|
              next if depth >= MAX_DEPTH || !seen.add?(path)
              inner = read_file(path)
              walk(inner, File.dirname(path), entries, stack.compact.flatten, seen, depth + 1) if inner
              seen.delete(path)
            end
          elsif line.match?(GLOB_RE)
            glob = line[GLOB_RE, 1]
            push_do_or_statement(stack, line)
          else
            push_do_or_statement(stack, line)
          end
        end
      end

      def read_file(path)
        File.read(path)
      rescue SystemCallError
        nil
      end

      def push_do_or_statement(stack, line)
        if line.match?(STATEMENT_RE)
          stack.push(nil) unless line.match?(/\bend\s*\z/)
        elsif line.match?(DO_BLOCK_RE)
          stack.push(nil)
        end
      end

      # 行内 eval_gemfile "path" / Dir.glob(...) 経由の eval_gemfile f を実ファイルに解決する
      def eval_files(line, glob, dir)
        return [] unless dir
        m = line.match(EVAL_RE)
        pattern = m[1] || glob
        return [] unless pattern
        File.expand_path(pattern, dir).then { |p| Dir.glob(p).sort }.select { File.file?(_1) }.map { File.realpath(_1) }
      end

      # コメントを除き、行末が , か \ の行は次の行と連結する
      def logical_lines(src)
        out = []
        buf = nil
        src.each_line do |raw|
          line = raw.sub(/(?<!["'\w])#.*/, "").rstrip
          if buf
            buf = "#{buf} #{line.strip}"
          else
            buf = line
          end
          if buf.end_with?(",") || buf.end_with?("\\")
            buf = buf.chomp("\\")
            next
          end
          out << buf
          buf = nil
        end
        out << buf if buf
        out
      end

      def add_gem(entries, line, block_groups)
        m = line.match(GEM_RE) or return
        name = m[1]
        groups = (block_groups + inline_groups(line)).uniq
        req = require_opt(line)
        if (old = entries[name])
          # if/else などで複数宣言されたら、全ての宣言が group 付きのときだけ group 付きとみなす
          groups = (old.groups.empty? || groups.empty?) ? [] : (old.groups | groups)
          req = nil unless old.require == req
        end
        entries[name] = Entry.new(name: name, groups: groups, require: req)
      end

      def symbols(str)
        found = []
        str.scan(PERCENT_RE) { |(body)| found.concat(body.split) }
        rest = str.gsub(PERCENT_RE, " ")
        found + rest.scan(/:(\w+)|["'](\w+)["']/).map { |a, b| a || b }
      end

      def inline_groups(line)
        m = line.match(/(?:\bgroups?:|:groups?\s*=>)\s*(\[[^\]]*\]|%[iIwW][\[(][^\])]*[\])]|:\w+|["']\w+["'])/)
        m ? symbols(m[1]) : []
      end

      def require_opt(line)
        m = line.match(/(?:\brequire:|:require\s*=>)\s*(false|nil|true|\[[^\]]*\]|%[iIwW][\[(][^\])]*[\])]|"[^"]*"|'[^']*')/)
        return nil unless m
        v = m[1]
        return false if v == "false"
        return nil if v == "nil" || v == "true"
        return v[PERCENT_RE, 1].split if v.start_with?("%")
        v.scan(/["']([^"']*)["']/).flatten
      end
    end
  end
end
