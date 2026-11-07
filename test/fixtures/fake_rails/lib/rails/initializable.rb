module Rails
  module Initializable
    class Initializer
      attr_reader :name, :block

      def initialize(name, context, &block)
        @name = name
        @context = context
        @block = block
      end

      def run(*args)
        @context.instance_exec(*args, &@block)
      end
    end
  end
end
