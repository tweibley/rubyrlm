module RubyRLM
  module Backends
    class Base
      def complete(messages:, generation_config: {})
        raise NotImplementedError, "#{self.class} must implement #complete"
      end
    end
  end
end
