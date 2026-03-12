# frozen_string_literal: true

module RubyRLM
  # Built-in pricing table for Gemini API models.
  # Rates are Paid-tier Standard prices in USD per 1 million tokens.
  # Source: https://ai.google.dev/gemini-api/docs/pricing
  module Pricing
    # Each entry: { input: $/1M, cached_input: $/1M, output: $/1M }
    # Models with tiered pricing use an array of { max_prompt_tokens:, input:, cached_input:, output: }
    RATES = {
      "gemini-3.1-pro-preview" => [
        { max_prompt_tokens: 200_000, input: 2.00, cached_input: 0.20, output: 12.00 },
        { max_prompt_tokens: Float::INFINITY, input: 4.00, cached_input: 0.40, output: 18.00 }
      ],
      "gemini-3-pro-preview" => [
        { max_prompt_tokens: 200_000, input: 2.00, cached_input: 0.20, output: 12.00 },
        { max_prompt_tokens: Float::INFINITY, input: 4.00, cached_input: 0.40, output: 18.00 }
      ],
      "gemini-3-flash-preview" => { input: 0.50, cached_input: 0.05, output: 3.00 },
      "gemini-2.5-pro" => { input: 1.25, cached_input: 0.31, output: 10.00 },
      "gemini-2.5-flash" => { input: 0.15, cached_input: 0.015, output: 0.60 },
      "gemini-2.5-flash-lite" => { input: 0.10, cached_input: 0.025, output: 0.40 },
      "gemini-2.0-flash" => { input: 0.10, cached_input: 0.025, output: 0.40 },
      "gemini-2.0-flash-lite" => { input: 0.10, cached_input: 0.025, output: 0.40 }
    }.freeze

    # Compute the USD cost for a single API call.
    #
    # @param model [String] the model name (e.g. "gemini-2.5-flash")
    # @param input_tokens [Integer] total input tokens (includes cached)
    # @param cached_tokens [Integer] how many input tokens were served from cache
    # @param output_tokens [Integer] output tokens (includes thinking tokens)
    # @return [Float] cost in USD
    def self.cost_for(model:, input_tokens: 0, cached_tokens: 0, output_tokens: 0)
      rate = resolve_rate(model.to_s)
      return 0.0 unless rate

      tier = select_tier(rate, input_tokens)
      return 0.0 unless tier

      uncached_input = [input_tokens - cached_tokens, 0].max
      per_m = 1_000_000.0

      (uncached_input / per_m * tier[:input]) +
        (cached_tokens / per_m * tier[:cached_input]) +
        (output_tokens / per_m * tier[:output])
    end

    # Look up the rate entry for a model, applying fuzzy matching for
    # suffixes like "-latest", "-001", date stamps, etc.
    #
    # @param model_name [String]
    # @return [Hash, Array, nil]
    def self.resolve_rate(model_name)
      name = model_name.to_s.downcase.strip

      # Direct match first
      return RATES[name] if RATES.key?(name)

      # Strip common suffixes: -latest, -001, -YYYYMMDD, etc.
      normalized = name
        .sub(/-latest\z/, "")
        .sub(/-\d{8,}\z/, "")
        .sub(/-\d{3}\z/, "")

      return RATES[normalized] if RATES.key?(normalized)

      # Try prefix match (e.g. "gemini-2.5-flash-preview-05-20" → "gemini-2.5-flash")
      RATES.keys
        .select { |key| normalized.start_with?(key) }
        .max_by(&:length)
        .then { |key| key ? RATES[key] : nil }
    end

    # Select the correct pricing tier for tiered models; for flat-rate
    # models just return the single rate hash.
    def self.select_tier(rate, input_tokens)
      case rate
      when Array
        rate.find { |tier| input_tokens <= tier[:max_prompt_tokens] } || rate.last
      when Hash
        rate
      end
    end

    # Return the list of known model names, sorted cheapest-first by input rate.
    def self.model_names
      RATES.keys.sort_by do |name|
        rate = RATES[name]
        case rate
        when Array then rate.first[:input]
        when Hash then rate[:input]
        end
      end
    end

    private_class_method :resolve_rate, :select_tier
  end
end
