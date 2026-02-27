require "securerandom"

module RubyRLM
  module Web
    module Services
      class EventBroadcaster
        def initialize
          @subscribers = {}
          @mutex = Mutex.new
        end

        def subscribe
          id = SecureRandom.hex(8)
          queue = Thread::Queue.new
          @mutex.synchronize { @subscribers[id] = queue }
          [id, queue]
        end

        def unsubscribe(subscriber_id)
          @mutex.synchronize { @subscribers.delete(subscriber_id) }
        end

        def broadcast(event)
          payload = event.is_a?(Hash) ? event.dup : event
          queues = @mutex.synchronize { @subscribers.values.dup }
          queues.each { |queue| queue.push(payload.dup) }
          payload
        end

        def subscriber_count
          @mutex.synchronize { @subscribers.size }
        end
      end
    end
  end
end
