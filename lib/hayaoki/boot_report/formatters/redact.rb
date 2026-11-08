# frozen_string_literal: true

module Hayaoki
  module BootReport
    module Formatters
      # 出力 (JSON / speedscope の文字列) から個人を特定できる絶対パスを消す。
      # gem のパスは <gem:name>/、アプリのルートは <app>、ホームは ~ に置き換える。
      class Redact
        GEM_PATH = %r{(?:/[^\s"/\\]+)+/gems/([^\s"/\\]+?)-(?:\d|[0-9a-f]{7,})[^\s"/\\]*/}

        def initialize(app_dir: nil, home: Dir.home)
          @apps = []
          if app_dir
            exp = File.expand_path(app_dir)
            real = (File.realpath(exp) rescue exp) # macOS: /var と /private/var
            @apps = [exp, real].uniq.sort_by { |a| -a.size }
          end
          @home = home
        end

        def apply(text)
          out = text.gsub(GEM_PATH) { "<gem:#{Regexp.last_match(1)}>/" }
          @apps.each do |a|
            out = out.gsub(/#{Regexp.escape(a)}(?=[\/"\s\\]|\z)/, "<app>") unless a == "/"
          end
          out = out.gsub(/#{Regexp.escape(@home)}(?=[\/"\s\\]|\z)/, "~") if @home && @home != "/"
          out
        end
      end
    end
  end
end
