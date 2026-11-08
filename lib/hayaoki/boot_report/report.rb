# frozen_string_literal: true

module Hayaoki
  module BootReport
    # 集計結果。to_h は JSON.generate に渡せる値 (String キーの Hash / Array / 数値 / nil) だけで作る。
    class Report
      ATTRS = %i[condition runs failed phases categories gems files initializers app_initializer_times on_loads eager_namespaces false_require threads
                 ruby features meta warnings].freeze
      attr_reader(*ATTRS)

      def initialize(**kw)
        unknown = kw.keys - ATTRS
        raise ArgumentError, "unknown keys: #{unknown.inspect}" unless unknown.empty?
        ATTRS.each { |a| instance_variable_set(:"@#{a}", kw[a]) }
      end

      def to_h
        ATTRS.to_h { |a| [a.to_s, public_send(a)] }
      end
    end
  end
end
