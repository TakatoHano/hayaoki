# frozen_string_literal: true

require "json"

module Hayaoki
  module ColdStartReport
    # Extracts cold_start lines from raw log text. Accepts bare JSON lines, Cloud Logging exports
    # (jsonPayload, array or JSONL), and CloudWatch lines (prefix before the JSON, or a "message" string).
    class Reader
      MARKER = /"hayaoki"\s*:\s*"cold_start"/
      CSV_HEADER = /\A"?@timestamp"?,"?@message/
      INIT_DURATION = /Init Duration: ([0-9.]+) ms/
      # Lambda platform line for an Init that ended badly or was retried; counted by phase and status.
      INIT_REPORT = /INIT_REPORT\b.*?Phase: ([a-z_]+).*?Status: ([a-z_]+)/i
      PLATFORM = Regexp.union(INIT_DURATION, /INIT_REPORT/)

      attr_reader :records, :platform_init_ms, :init_reports, :skipped_other, :skipped_invalid, :skipped_duplicate

      def initialize
        @records = []
        @platform_init_ms = []
        @init_reports = Hash.new(0) # [phase, status] => count
        @skipped_other = 0
        @skipped_invalid = 0
        @skipped_duplicate = 0
        @seen = {}
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
      # [{"phase", "status", "count"}] sorted, or nil when no INIT_REPORT line was seen
      def init_report_counts
        return nil if @init_reports.empty?
        @init_reports.sort.map { |(phase, status), c| { "phase" => phase, "status" => status, "count" => c } }
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

      def init_only?(item) = item.is_a?(String) && item.match?(PLATFORM)

      def read_line(line)
        line = line.strip
        return if line.empty?
        return if line.match?(CSV_HEADER)
        if line.start_with?('"') && line.include?('""')
          fields = csv_fields(line)
          if fields.any? { |f| f.match?(MARKER) || f.match?(PLATFORM) }
            fields.each { |f| read_line(f) if f.include?("{") || f.match?(PLATFORM) }
            return
          end
        end
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
          scan_init(line) unless found
          @skipped_invalid += 1 if !found && !line.match?(PLATFORM) && !line.include?("{")
          @skipped_other += 1 if !found && line.include?("{") && !line.match?(PLATFORM)
          return
        end
        # walk already scanned the strings inside obj for platform lines
        @skipped_other += 1 if @records.size == before && !line.match?(PLATFORM)
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
            add_record(node)
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

      # Same id + pid (+ worker) is the same boot seen twice (overlapping exports); keep the first.
      def add_record(node)
        return @records << node if node["id"].nil?
        key = [node["id"], node["pid"], node["worker"]]
        if @seen[key]
          @skipped_duplicate += 1
        else
          @seen[key] = true
          @records << node
        end
      end

      # Minimal RFC 4180 line split (quoted fields, "" escapes); CloudWatch Logs Insights CSV export.
      def csv_fields(line)
        fields = []
        cur = +""
        quoted = false
        i = 0
        while i < line.length
          c = line[i]
          if quoted
            if c == '"'
              if line[i + 1] == '"'
                cur << '"'
                i += 1
              else
                quoted = false
              end
            else
              cur << c
            end
          elsif c == '"' then quoted = true
          elsif c == "," then fields << cur
                              cur = +""
          else cur << c
          end
          i += 1
        end
        fields << cur
      end

      def scan_init(str)
        str.scan(INIT_DURATION) { |(v)| @platform_init_ms << v.to_f }
        str.scan(INIT_REPORT) { |phase, status| @init_reports[[phase.downcase, status.downcase]] += 1 }
      end

    end
  end
end
