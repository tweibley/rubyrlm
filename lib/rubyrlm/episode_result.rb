module RubyRLM
  # A String subclass that carries episode metadata from recursive subcalls.
  # Behaves exactly like a String (backward compatible with all existing code)
  # but exposes .episode, .iterations, and .forced_final for introspection.
  class EpisodeResult < String
    attr_reader :episode, :iterations, :forced_final

    def initialize(answer, episode: nil, iterations: nil, forced_final: false)
      super(answer.to_s)
      @episode = episode
      @iterations = iterations
      @forced_final = forced_final
    end
  end
end
