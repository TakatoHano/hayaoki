# frozen_string_literal: true

module Hayate
  module BootReport
    module Formatters
      # 出力 (JSON / speedscope の文字列) から個人を特定できる絶対パスを消す。
      # gem のパスは <gem:name>/、アプリのルートは <app>、ホームは ~ に置き換える。
      class Redact
        GEM_PATH = %r{(?:/[^\s"/\\]+)+/gems/([^\s"/\\]+?)-\d[^\s"/\\]*/}

        def initialize(app_dir: nil, home: Dir.home)
          @app = app_dir && File.expand_path(app_dir)
          @home = home
        end

        def apply(text)
          out = text.gsub(GEM_PATH) { "<gem:#{Regexp.last_match(1)}>/" }
          out = out.gsub(/#{Regexp.escape(@app)}(?=[\/"\s\\]|\z)/, "<app>") if @app && @app != "/"
          out = out.gsub(/#{Regexp.escape(@home)}(?=[\/"\s\\]|\z)/, "~") if @home && @home != "/"
          out
        end
      end
    end
  end
end
