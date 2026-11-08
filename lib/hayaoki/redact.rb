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
      p = path.to_s
      best = nil
      Array(specs).each do |name, dir|
        next if dir.nil? || dir.empty?
        next unless under?(p, dir)
        best = [name, dir] if best.nil? || dir.size > best[1].size
      end
      return "<gem:#{best[0]}>" if best
      m = GEM_PATH.match(p)
      return "<gem:#{m[1]}>" if m
      return "<app>" if app_roots(root).any? { |a| a != "/" && under?(p, a) }
      lib = RbConfig::CONFIG["rubylibdir"]
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
