# frozen_string_literal: true

require "json"

module Hayaoki
  module ColdStartReport
    # Extracts cold_start lines from raw log text. Accepts bare JSON lines, Cloud Logging exports
    # (jsonPayload, array or JSONL), and CloudWatch lines (prefix before the JSON, or a "message" string).
    class Reader
      MARKER = /"hayaoki"\s*:\s*"cold_start"/
      INIT_DURATION = /Init Duration: ([0-9.]+) ms/

      attr_reader :records, :platform_init_ms, :skipped_other, :skipped_invalid

      def initialize
        @records = []
        @platform_init_ms = []
        @skipped_other = 0
        @skipped_invalid = 0
      end

      # text: whole input. A single JSON document (array / object over many lines) is walked as one;
      # otherwise each line is read on its own.
      def read(text)
        stripped = text.lstrip
        if stripped.start_with?("[", "{") && (doc = parse(stripped))
          walk_top(doc)
        else
          text.each_line { |l| read_line(l) }
        end
        self
      end

      private

      def parse(str)
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def walk_top(doc)
        items = doc.is_a?(Array) ? doc : [doc]
        items.each do |item|
          before = @records.size
          walk(item)
          @skipped_other += 1 if @records.size == before && !init_only?(item)
        end
      end

      def init_only?(item) = item.is_a?(String) && item.match?(INIT_DURATION)

      def read_line(line)
        line = line.strip
        return if line.empty?
        before = @records.size
        found = false
        obj = line.start_with?("{") ? parse(line) : nil
        if obj
          found = true
          walk(obj)
        else
          i = line.index("{")
          obj = i && embedded(line[i..])
          if obj
            found = true
            walk(obj)
          end
          scan_init(line)
          @skipped_invalid += 1 if !found && !line.match?(INIT_DURATION) && !line.include?("{")
          @skipped_other += 1 if !found && line.include?("{") && !line.match?(INIT_DURATION)
          return
        end
        @skipped_other += 1 if @records.size == before && !line.match?(INIT_DURATION)
        scan_init(line) if @records.size == before
      end

      # Prefix-stripped text may carry a suffix too; try the largest balanced candidate first.
      def embedded(str)
        j = str.rindex("}")
        return nil unless j
        parse(str[0..j]) || (str.include?(MARKER.source[0, 2]) ? first_marker_object(str) : nil)
      end

      def first_marker_object(str)
        m = str.match(MARKER) or return nil
        starts = (0...m.begin(0)).select { |k| str[k] == "{" }.reverse
        starts.each do |s|
          e = str.length
          while (e = str.rindex("}", e - 1)) && e > s
            obj = parse(str[s..e])
            return obj if obj
          end
        end
        nil
      end

      def walk(node)
        case node
        when Hash
          if node["hayaoki"] == "cold_start"
            @records << node
          else
            node.each_value { |v| walk(v) }
          end
        when Array then node.each { |v| walk(v) }
        when String
          scan_init(node)
          if node.match?(MARKER) && (i = node.index("{"))
            obj = embedded(node[i..])
            walk(obj) if obj
          end
        end
      end

      def scan_init(str)
        str.scan(INIT_DURATION) { |(v)| @platform_init_ms << v.to_f }
      end
    end
  end
end
