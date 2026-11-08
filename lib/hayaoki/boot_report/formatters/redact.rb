# frozen_string_literal: true

require "hayaoki/redact"

module Hayaoki
  module BootReport
    module Formatters
      # 出力 (JSON / speedscope の文字列) から個人を特定できる絶対パスを消す。
      # gem のパスは <gem:name>/、アプリのルートは <app>、ホームは ~ に置き換える。
      class Redact
        GEM_PATH = Hayaoki::Redact::GEM_PATH

        def initialize(app_dir: nil, home: Dir.home)
          @apps = Hayaoki::Redact.app_roots(app_dir)
          @home = home
        end

        def apply(text)
          Hayaoki::Redact.redact_with(text, @apps, @home)
        end
      end
    end
  end
end
