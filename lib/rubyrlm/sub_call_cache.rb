require "digest"

module RubyRLM
  class SubCallCache
    attr_reader :hits, :misses

    def initialize
      @store = {}
      @hits = 0
      @misses = 0
    end

    def get(prompt, model_name:)
      key = cache_key(prompt, model_name)
      if @store.key?(key)
        @hits += 1
        @store[key]
      else
        @misses += 1
        nil
      end
    end

    def put(prompt, model_name:, response:)
      key = cache_key(prompt, model_name)
      @store[key] = response
    end

    def size
      @store.size
    end

    def stats
      {
        hits: @hits,
        misses: @misses,
        size: @store.size
      }
    end

    private

    def cache_key(prompt, model_name)
      Digest::SHA256.hexdigest("#{model_name}:#{prompt}")
    end
  end
end
