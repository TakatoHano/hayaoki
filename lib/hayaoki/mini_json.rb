# frozen_string_literal: true

# probe 用の最小 JSON エンコーダ。json ライブラリに依存しない (probe は子プロセスで先に読まれるため)。
module Hayaoki
  module MiniJSON
    ESC = { '"' => '\\"', "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

    NEEDS_ESCAPE = /["\\\x00-\x1f]/

    # 対象は String / Symbol / Integer / Float / nil / true / false / Array / Hash。
    # 文字列の大半はエスケープ不要なので、確認だけして引用符で囲む速い方法を先に試す。
    def self.encode(v)
      case v
      when String
        s = v.encoding == Encoding::UTF_8 ? v : v.dup.force_encoding(Encoding::UTF_8)
        if s.valid_encoding?
          return "\"#{s}\"" unless s.match?(NEEDS_ESCAPE)
        else
          s = s.scrub
        end
        "\"#{s.gsub(/["\\\u0000-\u001f]/) { |c| ESC[c] || format("\\u%04x", c.ord) }}\""
      when Symbol then encode(v.to_s)
      when Integer then v.to_s
      when Float then v.finite? ? v.to_s : "null"
      when nil then "null"
      when true, false then v.to_s
      when Array
        return "[#{v.join(",")}]" if v.all?(Integer) # Integer だけの配列はまとめて連結する
        "[#{v.map { |x| encode(x) }.join(",")}]"
      when Hash then "{#{v.map { |k, x| "#{encode(k.to_s)}:#{encode(x)}" }.join(",")}}"
      else encode(v.to_s)
      end
    end
  end
end
