# frozen_string_literal: true

require "json"
require_relative "../../version"

module Hayate
  module BootReport
    module Formatters
      # payload (probe の出力) 1 回分を speedscope の evented 形式にする。メインスレッド (tid 0) のみ。
      class Speedscope
        SCHEMA = "https://www.speedscope.app/file-format-schema.json"
        KINDS = %w[require require_relative load initializer on_load hooks eager_load phase].freeze

        # payloads: 配列。boot の total に一番近い (=中央値に近い) run を選ぶ。
        def self.pick_median(payloads)
          ok = payloads.select { |p| p["status"] == "ok" }
          ok = payloads if ok.empty?
          sorted = ok.sort_by { |p| p["boot_end_us"] || p["exit_us"] || 0 }
          sorted[sorted.size / 2]
        end

        def initialize(name: "hayate boot")
          @name = name
        end

        # RunResult の payloads (Hash) / 配列 / 単一 payload を受け付ける。
        def format(input, condition: nil)
          payload = pick(input, condition)
          ::JSON.generate(build(payload)) + "\n"
        end

        def build(payload)
          w = payload["width"] || 8
          ev = payload["events"] || []
          exit_us = payload["exit_us"] || ev.each_slice(w).filter_map { |e| e[4] }.max || 0
          spans = ev.each_slice(w).with_index.map do |(kind, n, par, t0, t1, _res, tid), i|
            { idx: i * w, kind: kind, name: n, parent: par, t0: t0, t1: t1 || [exit_us, t0].max, tid: tid.to_i, kids: [] }
          end
          main = spans.select { |s| s[:tid].zero? }
          by = main.to_h { |s| [s[:idx], s] }
          roots = []
          main.each { |s| (by[s[:parent]] ? by[s[:parent]][:kids] : roots) << s }
          origin = main.map { |s| s[:t0] }.min || 0
          frames = []
          fidx = {}
          events = []
          emit = lambda do |s, lo, hi|
            a = [[s[:t0], lo].max, hi].min
            b = [[s[:t1], a].max, hi].min
            key = [s[:kind], s[:name]]
            f = (fidx[key] ||= (frames << { "name" => "#{KINDS[s[:kind]] || s[:kind]}: #{s[:name]}" }; frames.size - 1))
            events << { "type" => "O", "frame" => f, "at" => a - origin }
            cursor = a
            s[:kids].sort_by { |k| k[:t0] }.each do |k|
              next if k[:t0] < cursor && k[:t1] <= cursor
              emit.call(k, cursor, b)
              cursor = [cursor, [k[:t1], b].min].max
            end
            events << { "type" => "C", "frame" => f, "at" => b - origin }
          end
          cursor = origin
          roots.sort_by { |s| s[:t0] }.each do |s|
            next if s[:t1] <= cursor && s[:t0] < cursor
            emit.call(s, cursor, [s[:t1], cursor].max)
            cursor = [cursor, s[:t1]].max
          end
          end_value = [events.map { |e| e["at"] }.max || 0, 0].max
          {
            "$schema" => SCHEMA,
            "shared" => { "frames" => frames },
            "profiles" => [{ "type" => "evented", "name" => @name, "unit" => "microseconds",
                             "startValue" => 0, "endValue" => end_value, "events" => events }],
            "name" => @name, "activeProfileIndex" => 0, "exporter" => "hayate #{Hayate::VERSION}"
          }
        end

        private

        def pick(input, condition)
          case input
          when Hash
            if input.key?("events") then input
            else self.class.pick_median(condition ? input[condition.to_s] : input.values.first)
            end
          when Array then self.class.pick_median(input)
          else
            list = condition ? input.payloads[condition.to_s] : input.payloads.values.first
            self.class.pick_median(list)
          end
        end
      end
    end
  end
end
