# frozen_string_literal: true

require "json"

module Hayaoki
  module ColdStartReport
    module Formatters
      class Json
        # result: { "summary" =>, "groups" => { key => summary }|nil, "input" => {} }
        def format(result)
          out = { "hayaoki_report" => "cold_start", "v" => 1 }.merge(result.reject { |_, v| v.nil? })
          JSON.pretty_generate(out) + "\n"
        end
      end
    end
  end
end
