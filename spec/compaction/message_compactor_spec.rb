require "spec_helper"

RSpec.describe RubyRLM::Compaction::MessageCompactor do
  def build_messages(count)
    messages = [
      { role: "system", content: "You are RubyRLM." },
      { role: "user", content: "Context summary: hello" }
    ]
    remaining = count - 2
    (remaining / 2).times do |i|
      messages << { role: "assistant", content: "{\"action\":\"exec\",\"code\":\"step_#{i}\"}" }
      messages << { role: "user", content: "Execution result: ok_#{i}" }
    end
    messages << { role: "assistant", content: "extra" } if remaining.odd?
    messages
  end

  let(:fake_backend) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def complete(messages:, generation_config: {})
        @calls << { messages: messages, generation_config: generation_config }
        {
          text: "Summary: executed steps 0-4, all succeeded.",
          usage: { prompt_tokens: 100, candidate_tokens: 50, total_tokens: 150 },
          latency_s: 0.05
        }
      end
    end.new
  end

  let(:compactor) do
    described_class.new(
      enabled: true,
      threshold: 0.7,
      max_messages: 10,
      backend_builder: ->(model_name:) { fake_backend }
    )
  end

  it "does not compact when below threshold" do
    messages = build_messages(6) # 6 < ceil(10 * 0.7) = 7
    result = compactor.maybe_compact!(messages)
    expect(result.compacted).to be false
    expect(messages.length).to eq 6
  end

  it "compacts when at threshold" do
    messages = build_messages(8) # 8 >= ceil(10 * 0.7) = 7
    result = compactor.maybe_compact!(messages)
    expect(result.compacted).to be true
    expect(messages.length).to eq 3 # 2 pinned + 1 summary
    expect(messages[2][:content]).to include("[Context summary")
  end

  it "preserves pinned messages verbatim" do
    messages = build_messages(8)
    original_system = messages[0].dup
    original_initial = messages[1].dup
    compactor.maybe_compact!(messages)
    expect(messages[0]).to eq original_system
    expect(messages[1]).to eq original_initial
  end

  it "returns usage from backend call" do
    messages = build_messages(8)
    result = compactor.maybe_compact!(messages)
    expect(result.usage[:total_tokens]).to eq 150
  end

  it "returns message counts" do
    messages = build_messages(8)
    result = compactor.maybe_compact!(messages)
    expect(result.messages_before).to eq 8
    expect(result.messages_after).to eq 3
  end

  it "does nothing when disabled" do
    disabled = described_class.new(
      enabled: false,
      threshold: 0.1,
      max_messages: 10,
      backend_builder: ->(model_name:) { raise "should not be called" }
    )
    messages = build_messages(50)
    result = disabled.maybe_compact!(messages)
    expect(result.compacted).to be false
  end

  it "raises CompactionError when backend fails" do
    failing_backend = Class.new do
      def complete(messages:, generation_config: {})
        raise RubyRLM::BackendError, "network timeout"
      end
    end.new

    compactor = described_class.new(
      enabled: true,
      threshold: 0.5,
      max_messages: 6,
      backend_builder: ->(model_name:) { failing_backend }
    )
    messages = build_messages(6)
    expect { compactor.maybe_compact!(messages) }.to raise_error(RubyRLM::CompactionError)
  end

  it "sends correct prompt structure to backend" do
    messages = build_messages(8)
    compactor.maybe_compact!(messages)

    call = fake_backend.calls.first
    expect(call[:messages].length).to eq 2
    expect(call[:messages][0][:role]).to eq "system"
    expect(call[:messages][0][:content]).to include("summarizer")
    expect(call[:messages][1][:role]).to eq "user"
    expect(call[:messages][1][:content]).to include("CONVERSATION TO SUMMARIZE")
    expect(call[:generation_config][:response_mime_type]).to eq "text/plain"
  end
end
