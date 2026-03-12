require "digest"
require "monitor"

module RubyRLM
  class SubCallCache
    def initialize
      @store = {}
      @hits = 0
      @misses = 0
      @mon = Monitor.new
    end

    def hits
      @mon.synchronize { @hits }
    end

    def misses
      @mon.synchronize { @misses }
    end

    def get(prompt, model_name:)
      key = cache_key(prompt, model_name)
      @mon.synchronize do
        if @store.key?(key)
          @hits += 1
          @store[key]
        else
          @misses += 1
          nil
        end
      end
    end

    def put(prompt, model_name:, response:)
      key = cache_key(prompt, model_name)
      @mon.synchronize { @store[key] = response }
    end

    def size
      @mon.synchronize { @store.size }
    end

    def stats
      @mon.synchronize do
        {
          hits: @hits,
          misses: @misses,
          size: @store.size
        }
      end
    end

    private

    def cache_key(prompt, model_name)
      Digest::SHA256.hexdigest("#{model_name}:#{prompt}")
    end
  end
end
