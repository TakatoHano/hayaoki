# frozen_string_literal: true

require "rbconfig"

module Hayaoki
  # パスのグルーピングと文字列のマスク。標準ライブラリ以外に依存しない
  # (本番プロセス内の in-situ ロガーからも使う)。
  module Redact
    GEM_PATH = %r{(?:/[^\s"/\\]+)+/gems/([^\s"/\\]+?)-(?:\d|[0-9a-f]{7,})[^\s"/\\]*/}
    BOUNDARY = %r{(?=[/"\s\\]|\z)}

    module_function

    # アプリのルートの候補 (展開後と realpath)。長い順。macOS: /var と /private/var
    def app_roots(app_dir)
      return [] unless app_dir
      exp = File.expand_path(app_dir)
      real = (File.realpath(exp) rescue exp)
      [exp, real].uniq.sort_by { |a| -a.size }
    end

    # specs: [[name, full_gem_path], ...]。
    # 戻り値: "<gem:name>" / "<app>" / "<stdlib>" / "<other>"
    def group_for(path, specs, root)
      group_with(path, index(specs, root))
    end

    # group_for の前処理 (specs と root が同じなら 1 回でよい)。パスごとに作り直すと
    # specs 数 x パス数の文字列生成と realpath が走る。
    def index(specs, root)
      by_dir = {}
      Array(specs).each do |name, dir|
        next if dir.nil? || dir.empty?
        by_dir[dir.end_with?("/") && dir.size > 1 ? dir.chomp("/") : dir] ||= name # 同じ dir は先勝ち
      end
      [by_dir, app_roots(root).reject { _1 == "/" }, RbConfig::CONFIG["rubylibdir"]]
    end

    # 祖先ディレクトリを深い方から引くので、最長一致になる (path 自身が dir の場合も一致)。
    def group_with(path, idx)
      p = path.to_s
      by_dir, roots, lib = idx
      d = p
      loop do
        name = by_dir[d] and return "<gem:#{name}>"
        i = d.rindex("/") or break
        if i.zero?
          name = by_dir["/"] and return "<gem:#{name}>"
          break
        end
        d = d[0, i]
      end
      m = GEM_PATH.match(p)
      return "<gem:#{m[1]}>" if m
      return "<app>" if roots.any? { under?(p, _1) }
      return "<stdlib>" if lib && under?(p, lib)
      "<other>"
    end

    # テキスト中の絶対パスをマスクする。gem は <gem:name>/、アプリは <app>、ホームは ~。
    def redact_string(text, app_dir: nil, home: Dir.home)
      redact_with(text, app_roots(app_dir), home)
    end

    def redact_with(text, apps, home)
      out = text.gsub(GEM_PATH) { "<gem:#{Regexp.last_match(1)}>/" }
      apps.each do |a|
        out = out.gsub(/#{Regexp.escape(a)}#{BOUNDARY}/, "<app>") unless a == "/"
      end
      out = out.gsub(/#{Regexp.escape(home)}#{BOUNDARY}/, "~") if home && home != "/"
      out
    end

    def under?(path, dir)
      d = dir.end_with?("/") ? dir : "#{dir}/"
      path.start_with?(d) || path == dir
    end
  end
end
