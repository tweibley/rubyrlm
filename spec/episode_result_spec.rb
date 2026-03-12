require "spec_helper"

RSpec.describe RubyRLM::EpisodeResult do
  it "behaves as a String" do
    result = described_class.new("the answer", episode: "did stuff", iterations: 3)
    expect(result).to eq("the answer")
    expect(result.length).to eq(10)
    expect(result.upcase).to eq("THE ANSWER")
    expect("prefix: #{result}").to eq("prefix: the answer")
  end

  it "exposes episode metadata" do
    result = described_class.new("answer", episode: "step 1: exec, step 2: final", iterations: 2, forced_final: true)
    expect(result.episode).to eq("step 1: exec, step 2: final")
    expect(result.iterations).to eq(2)
    expect(result.forced_final).to be true
  end

  it "defaults forced_final to false" do
    result = described_class.new("answer")
    expect(result.forced_final).to be false
    expect(result.episode).to be_nil
    expect(result.iterations).to be_nil
  end
end
