require "monitor"

module RubyRLM
  class BudgetTracker
    attr_reader :limits

    def initialize(max_subcalls: nil, max_total_tokens: nil, max_cost_usd: nil)
      @limits = {
        max_subcalls: max_subcalls,
        max_total_tokens: max_total_tokens,
        max_cost_usd: max_cost_usd
      }.compact
      @subcalls = 0
      @total_tokens = 0
      @total_cost = 0.0
      @mon = Monitor.new
    end

    def check_subcall!
      @mon.synchronize do
        @subcalls += 1
        if @limits[:max_subcalls] && @subcalls > @limits[:max_subcalls]
          raise BudgetExceededError, "max_subcalls limit of #{@limits[:max_subcalls]} reached"
        end
      end
    end

    def add_usage(tokens:, cost:)
      @mon.synchronize do
        @total_tokens += tokens.to_i
        @total_cost += cost.to_f
        if @limits[:max_total_tokens] && @total_tokens > @limits[:max_total_tokens]
          raise BudgetExceededError, "max_total_tokens limit of #{@limits[:max_total_tokens]} reached (current: #{@total_tokens})"
        end
        if @limits[:max_cost_usd] && @total_cost > @limits[:max_cost_usd]
          raise BudgetExceededError, "max_cost_usd limit of #{@limits[:max_cost_usd]} reached (current: #{format('%.6f', @total_cost)})"
        end
      end
    end

    def stats
      @mon.synchronize do
        {
          subcalls: @subcalls,
          total_tokens: @total_tokens,
          total_cost: @total_cost.round(6),
          limits: @limits
        }
      end
    end

    def exceeded?
      @mon.synchronize do
        return true if @limits[:max_subcalls] && @subcalls > @limits[:max_subcalls]
        return true if @limits[:max_total_tokens] && @total_tokens > @limits[:max_total_tokens]
        return true if @limits[:max_cost_usd] && @total_cost > @limits[:max_cost_usd]

        false
      end
    end
  end
end
