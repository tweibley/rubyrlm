require "spec_helper"

RSpec.describe RubyRLM::UsageSummary do
  it "accepts symbol and string usage keys" do
    summary = described_class.new

    summary.add({ prompt_tokens: 2, candidate_tokens: 3, total_tokens: 5 })
    summary.add({ "prompt_tokens" => 7, "candidate_tokens" => 11, "total_tokens" => 18 })

    expect(summary.to_h).to include(
      prompt_tokens: 9,
      candidate_tokens: 14,
      total_tokens: 23,
      calls: 2
    )
  end

  it "tracks cached_content_tokens" do
    summary = described_class.new
    summary.add({ prompt_tokens: 100, candidate_tokens: 50, cached_content_tokens: 40, total_tokens: 150 })

    expect(summary.cached_content_tokens).to eq(40)
    expect(summary.to_h[:cached_content_tokens]).to eq(40)
  end

  it "accumulates total_cost when model is provided" do
    summary = described_class.new
    summary.add(
      { prompt_tokens: 1_000_000, candidate_tokens: 1_000_000, cached_content_tokens: 0, total_tokens: 2_000_000 },
      model: "gemini-2.5-flash"
    )

    # $0.15 input + $0.60 output = $0.75
    expect(summary.total_cost).to be_within(0.001).of(0.75)
    expect(summary.to_h[:total_cost]).to be_within(0.001).of(0.75)
  end

  it "does not add cost when model is nil" do
    summary = described_class.new
    summary.add({ prompt_tokens: 1_000_000, candidate_tokens: 1_000_000, total_tokens: 2_000_000 })

    expect(summary.total_cost).to eq(0.0)
  end

  it "reduces cost with cached tokens" do
    no_cache = described_class.new
    no_cache.add(
      { prompt_tokens: 1_000_000, candidate_tokens: 0, cached_content_tokens: 0, total_tokens: 1_000_000 },
      model: "gemini-2.5-flash"
    )

    with_cache = described_class.new
    with_cache.add(
      { prompt_tokens: 1_000_000, candidate_tokens: 0, cached_content_tokens: 800_000, total_tokens: 1_000_000 },
      model: "gemini-2.5-flash"
    )

    expect(with_cache.total_cost).to be < no_cache.total_cost
  end
end
