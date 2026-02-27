require "spec_helper"

RSpec.describe RubyRLM::Pricing do
  describe ".cost_for" do
    it "computes cost for a known flat-rate model" do
      cost = described_class.cost_for(
        model: "gemini-2.5-flash",
        input_tokens: 1_000_000,
        cached_tokens: 0,
        output_tokens: 1_000_000
      )

      # $0.15 input + $0.60 output = $0.75
      expect(cost).to be_within(0.001).of(0.75)
    end

    it "applies cached token discount" do
      full_cost = described_class.cost_for(
        model: "gemini-2.5-flash",
        input_tokens: 1_000_000,
        cached_tokens: 0,
        output_tokens: 0
      )

      cached_cost = described_class.cost_for(
        model: "gemini-2.5-flash",
        input_tokens: 1_000_000,
        cached_tokens: 800_000,
        output_tokens: 0
      )

      expect(cached_cost).to be < full_cost
    end

    it "uses tiered pricing for gemini-3.1-pro-preview with small prompts" do
      cost = described_class.cost_for(
        model: "gemini-3.1-pro-preview",
        input_tokens: 100_000,
        cached_tokens: 0,
        output_tokens: 100_000
      )

      # (100k/1M * $2.00) + (100k/1M * $12.00) = $0.20 + $1.20 = $1.40
      expect(cost).to be_within(0.001).of(1.40)
    end

    it "uses higher tier for gemini-3.1-pro-preview with large prompts" do
      cost = described_class.cost_for(
        model: "gemini-3.1-pro-preview",
        input_tokens: 300_000,
        cached_tokens: 0,
        output_tokens: 100_000
      )

      # (300k/1M * $4.00) + (100k/1M * $18.00) = $1.20 + $1.80 = $3.00
      expect(cost).to be_within(0.001).of(3.00)
    end

    it "resolves model with -latest suffix" do
      cost = described_class.cost_for(
        model: "gemini-2.5-flash-latest",
        input_tokens: 1_000_000,
        cached_tokens: 0,
        output_tokens: 0
      )

      expect(cost).to be_within(0.001).of(0.15)
    end

    it "resolves model with date suffix" do
      cost = described_class.cost_for(
        model: "gemini-2.5-flash-20260101",
        input_tokens: 1_000_000,
        cached_tokens: 0,
        output_tokens: 0
      )

      expect(cost).to be_within(0.001).of(0.15)
    end

    it "returns 0.0 for unknown models" do
      cost = described_class.cost_for(
        model: "gpt-4o",
        input_tokens: 1_000_000,
        cached_tokens: 0,
        output_tokens: 1_000_000
      )

      expect(cost).to eq(0.0)
    end

    it "handles zero tokens gracefully" do
      cost = described_class.cost_for(
        model: "gemini-2.5-pro",
        input_tokens: 0,
        cached_tokens: 0,
        output_tokens: 0
      )

      expect(cost).to eq(0.0)
    end

    it "clamps uncached input to zero when cached exceeds input" do
      cost = described_class.cost_for(
        model: "gemini-2.5-flash",
        input_tokens: 100,
        cached_tokens: 200,
        output_tokens: 0
      )

      # Should not go negative — only cached rate applies
      expect(cost).to be >= 0.0
    end
  end
end
