# frozen_string_literal: true

require_relative "../gemfile"

module Hayate
  module BootReport
    # Report / RunResult は Hash のキーが String でも Symbol でも動くように、値の取り出しはこの補助を通す。
    module Access
      module_function

      # obj が Hash なら String / Symbol 両方のキーを試す。それ以外は同名のメソッドを呼ぶ。
      def get(obj, *keys)
        keys.reduce(obj) do |cur, key|
          return nil if cur.nil?
          if cur.is_a?(Hash)
            if cur.key?(key.to_s) then cur[key.to_s]
            elsif cur.key?(key.to_sym) then cur[key.to_sym]
            end
          elsif cur.respond_to?(key)
            cur.public_send(key)
          end
        end
      end

      # { "median" => x, ... } でも数値でもよい。
      def med(stat)
        v = stat.is_a?(Hash) ? get(stat, :median) : stat
        v.is_a?(Numeric) ? v.to_f : nil
      end

      def round(x) = x.nil? ? nil : x.round(1)
    end

    # ルールが受け取る入力一式。
    Context = Struct.new(:report, :app_dir, :result, :initializer_threshold_ms, :gem_threshold_ms, keyword_init: true) do
      def gems = Array(Access.get(report, :gems))
      def meta = Access.get(report, :meta) || {}
      def env = (Access.get(meta, :env) || Access.get(result, :meta, :env)).to_s

      def warnings
        (Array(Access.get(report, :warnings)) + Array(Access.get(result, :meta, :warnings))).map(&:to_s)
      end

      def phase_ms(name) = Access.med(Access.get(report, :phases, name))
    end

    module Rules
      # 各ルールの基底。call は Suggestion の配列を返す。
      class Base
        include Hayate::BootReport::Access

        def self.rule_id = name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym

        def initialize(ctx)
          @ctx = ctx
        end

        def call = raise(NotImplementedError)

        private

        attr_reader :ctx

        def suggestion(confidence, title:, evidence:, action:, savings: nil)
          Suggestion.new(rule: self.class.rule_id, confidence: confidence, title: title, evidence: evidence,
                         estimated_savings_ms: savings && savings.round(1), action: action)
        end

        # Gemfile の中身 (無ければ nil)
        def gemfile
          path = File.join(ctx.app_dir.to_s, "Gemfile")
          File.file?(path) ? File.read(path) : nil
        rescue SystemCallError
          nil
        end

        # Gemfile を解析した { gem 名 => Gemfile::Entry }。Gemfile が無ければ nil。
        def gemfile_entries
          return @gemfile_entries if defined?(@gemfile_entries)
          src = gemfile
          @gemfile_entries = src && Hayate::BootReport::Gemfile.parse(src)
        end
      end
    end
  end
end
