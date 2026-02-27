module RubyRLM
  class UsageSummary
    attr_reader :prompt_tokens, :candidate_tokens, :cached_content_tokens, :total_tokens, :calls, :total_cost

    def initialize
      @prompt_tokens = 0
      @candidate_tokens = 0
      @cached_content_tokens = 0
      @total_tokens = 0
      @calls = 0
      @total_cost = 0.0
    end

    def add(usage_hash, model: nil)
      @calls += 1
      return unless usage_hash.is_a?(Hash)

      usage = usage_hash.each_with_object({}) { |(key, value), memo| memo[key.to_sym] = value }
      input = Integer(usage.fetch(:prompt_tokens, 0))
      output = Integer(usage.fetch(:candidate_tokens, 0))
      cached = Integer(usage.fetch(:cached_content_tokens, 0))

      @prompt_tokens += input
      @candidate_tokens += output
      @cached_content_tokens += cached
      @total_tokens += Integer(usage.fetch(:total_tokens, 0))

      if model
        @total_cost += Pricing.cost_for(
          model: model,
          input_tokens: input,
          cached_tokens: cached,
          output_tokens: output
        )
      end
    end

    def to_h
      {
        prompt_tokens: @prompt_tokens,
        candidate_tokens: @candidate_tokens,
        cached_content_tokens: @cached_content_tokens,
        total_tokens: @total_tokens,
        calls: @calls,
        total_cost: @total_cost.round(6)
      }
    end
  end

  class CompletionResult
    attr_reader :response, :execution_time, :usage_summary, :root_model, :metadata

    def initialize(response:, execution_time:, usage_summary:, root_model:, metadata:)
      @response = response
      @execution_time = execution_time
      @usage_summary = usage_summary
      @root_model = root_model
      @metadata = metadata
    end

    def to_h
      {
        response: @response,
        execution_time: @execution_time,
        usage_summary: @usage_summary.to_h,
        root_model: @root_model,
        metadata: @metadata
      }
    end
  end
end
