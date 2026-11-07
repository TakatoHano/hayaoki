require "rails/initializable"

module Rails
  class Application
    def self.initializers = (@initializers ||= [])

    def initialize!(group = :default)
      self.class.initializers.each do |name, block|
        Initializable::Initializer.new(name, self, &block).run
      end
      @initialized = true
      self
    end

    def initialized? = @initialized == true
  end
end
