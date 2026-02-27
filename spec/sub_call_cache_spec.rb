require "spec_helper"

RSpec.describe RubyRLM::SubCallCache do
  subject(:cache) { described_class.new }

  it "returns nil on cache miss" do
    result = cache.get("What is 2+2?", model_name: "gemini-2.5-flash")
    expect(result).to be_nil
    expect(cache.misses).to eq(1)
    expect(cache.hits).to eq(0)
  end

  it "returns cached response on cache hit" do
    cache.put("What is 2+2?", model_name: "gemini-2.5-flash", response: "4")
    result = cache.get("What is 2+2?", model_name: "gemini-2.5-flash")
    expect(result).to eq("4")
    expect(cache.hits).to eq(1)
  end

  it "treats different model names as different cache keys" do
    cache.put("hello", model_name: "model-a", response: "answer-a")
    cache.put("hello", model_name: "model-b", response: "answer-b")

    expect(cache.get("hello", model_name: "model-a")).to eq("answer-a")
    expect(cache.get("hello", model_name: "model-b")).to eq("answer-b")
    expect(cache.size).to eq(2)
  end

  it "treats different prompts as different cache keys" do
    cache.put("prompt-1", model_name: "m", response: "r1")
    cache.put("prompt-2", model_name: "m", response: "r2")

    expect(cache.get("prompt-1", model_name: "m")).to eq("r1")
    expect(cache.get("prompt-2", model_name: "m")).to eq("r2")
  end

  it "tracks stats accurately across multiple operations" do
    cache.put("q1", model_name: "m", response: "a1")

    cache.get("q1", model_name: "m")  # hit
    cache.get("q1", model_name: "m")  # hit
    cache.get("q2", model_name: "m")  # miss

    stats = cache.stats
    expect(stats).to eq({ hits: 2, misses: 1, size: 1 })
  end
end
