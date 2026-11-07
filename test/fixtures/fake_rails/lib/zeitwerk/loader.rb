module Zeitwerk
  class Loader
    attr_reader :tag

    def initialize(tag = "rails.main") = @tag = tag

    def eager_load(force: false)
      sleep 0.005
      nil
    end
  end
end
