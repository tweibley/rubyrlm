require "spec_helper"

RSpec.describe RubyRLM::BudgetTracker do
  it "tracks subcall count and enforces limit" do
    tracker = described_class.new(max_subcalls: 3)
    tracker.check_subcall!
    tracker.check_subcall!
    tracker.check_subcall!
    expect { tracker.check_subcall! }.to raise_error(RubyRLM::BudgetExceededError, /max_subcalls/)
    expect(tracker.stats[:subcalls]).to eq 4
  end

  it "tracks token usage and enforces limit" do
    tracker = described_class.new(max_total_tokens: 100)
    tracker.add_usage(tokens: 60, cost: 0.01)
    expect { tracker.add_usage(tokens: 50, cost: 0.01) }.to raise_error(RubyRLM::BudgetExceededError, /max_total_tokens/)
    expect(tracker.stats[:total_tokens]).to eq 110
  end

  it "tracks cost and enforces limit" do
    tracker = described_class.new(max_cost_usd: 0.50)
    tracker.add_usage(tokens: 100, cost: 0.30)
    expect { tracker.add_usage(tokens: 100, cost: 0.25) }.to raise_error(RubyRLM::BudgetExceededError, /max_cost_usd/)
    expect(tracker.stats[:total_cost]).to eq 0.55
  end

  it "allows unlimited usage when no limits set" do
    tracker = described_class.new
    100.times { tracker.check_subcall! }
    tracker.add_usage(tokens: 1_000_000, cost: 100.0)
    expect(tracker.stats[:subcalls]).to eq 100
    expect(tracker.stats[:total_tokens]).to eq 1_000_000
  end

  it "reports exceeded? accurately" do
    tracker = described_class.new(max_subcalls: 2)
    expect(tracker.exceeded?).to be false
    tracker.check_subcall!
    expect(tracker.exceeded?).to be false
    tracker.check_subcall!
    expect(tracker.exceeded?).to be false
    expect { tracker.check_subcall! }.to raise_error(RubyRLM::BudgetExceededError)
    expect(tracker.exceeded?).to be true
  end

  it "returns limits in stats" do
    tracker = described_class.new(max_subcalls: 10, max_cost_usd: 1.0)
    stats = tracker.stats
    expect(stats[:limits]).to eq({ max_subcalls: 10, max_cost_usd: 1.0 })
  end

  it "is thread-safe for concurrent subcall checks" do
    tracker = described_class.new(max_subcalls: 100)
    threads = 10.times.map do
      Thread.new { 10.times { tracker.check_subcall! } }
    end
    threads.each(&:join)
    expect(tracker.stats[:subcalls]).to eq 100
  end

  it "is thread-safe for concurrent usage tracking" do
    tracker = described_class.new
    threads = 10.times.map do
      Thread.new { 10.times { tracker.add_usage(tokens: 1, cost: 0.001) } }
    end
    threads.each(&:join)
    expect(tracker.stats[:total_tokens]).to eq 100
    expect(tracker.stats[:total_cost]).to be_within(0.0001).of(0.1)
  end
end
