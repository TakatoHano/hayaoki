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

        # Gemfile のパス。BUNDLE_GEMFILE (絶対 / app からの相対) > <app>/Gemfile > <app>/gems.rb。無ければ nil
        def gemfile_path
          return @gemfile_path if defined?(@gemfile_path)
          app = ctx.app_dir.to_s
          env = ENV["BUNDLE_GEMFILE"].to_s
          candidates = []
          candidates << File.expand_path(env, app) unless env.empty?
          candidates << File.join(app, "Gemfile") << File.join(app, "gems.rb")
          @gemfile_path = candidates.find { File.file?(_1) }
        end

        # Gemfile の中身 (無ければ nil)
        def gemfile
          path = gemfile_path
          path && File.read(path)
        rescue SystemCallError
          nil
        end

        # Gemfile を解析した { gem 名 => Gemfile::Entry } (eval_gemfile 先を含む)。Gemfile が無ければ nil。
        def gemfile_entries
          return @gemfile_entries if defined?(@gemfile_entries)
          src = gemfile
          @gemfile_entries = src && Hayate::BootReport::Gemfile.parse(src, dir: File.dirname(gemfile_path))
        end

        # 子プロセスの payload が記録した gem の full_gem_path ({ name => path })。計測対象 app の bundle を指す。
        def gem_paths = @gem_paths ||= spec_field(1)

        # 子プロセスが記録した gem のバージョン (アプリの bundle のもの)
        def gem_versions = @gem_versions ||= spec_field(0)

        def spec_field(i)
          pl = get(ctx.result, :payloads)
          lists = pl.is_a?(Hash) ? pl.values : []
          lists.flatten.each_with_object({}) do |p, h|
            specs = get(p, :specs)
            next unless specs.is_a?(Hash)
            specs.each { |name, info| h[name.to_s] ||= info[i] if info.is_a?(Array) && info[i] }
          end
        end
      end
    end
  end
end
