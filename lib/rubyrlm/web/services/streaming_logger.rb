module RubyRLM
  module Web
    module Services
      class StreamingLogger
        def initialize(jsonl_logger:, broadcaster:)
          @jsonl_logger = jsonl_logger
          @broadcaster = broadcaster
        end

        def log(event)
          @jsonl_logger.log(event)
          @broadcaster.broadcast(event)
        end

        # Needed to match JsonlLogger interface
        def respond_to?(method, include_all = false)
          method.to_sym == :log || super
        end
      end
    end
  end
end
