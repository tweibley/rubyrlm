require "spec_helper"

RSpec.describe RubyRLM::Backends::GeminiRest do
  let(:api_key) { "test-key" }
  let(:model_name) { "gemini-3.1-pro-preview" }
  let(:endpoint) do
    "https://generativelanguage.googleapis.com/v1beta/models/#{model_name}:generateContent?key=#{api_key}"
  end
  let(:stream_endpoint) do
    "https://generativelanguage.googleapis.com/v1beta/models/#{model_name}:streamGenerateContent?alt=sse&key=#{api_key}"
  end

  it "parses text and usage metadata from successful response" do
    stub_request(:post, endpoint)
      .to_return(
        status: 200,
        body: {
          candidates: [{ content: { parts: [{ text: "{\"action\":\"final\",\"answer\":\"ok\"}" }] } }],
          usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 7 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    backend = described_class.new(model_name: model_name, api_key: api_key, max_retries: 0)
    response = backend.complete(messages: [{ role: "user", content: "hi" }], generation_config: {})

    expect(response[:text]).to include("\"action\":\"final\"")
    expect(response[:usage]).to eq(prompt_tokens: 3, candidate_tokens: 4, thoughts_tokens: 0, cached_content_tokens: 0, total_tokens: 7)
  end

  it "retries transient 429 responses and then succeeds" do
    stub_request(:post, endpoint)
      .to_return(
        { status: 429, body: { error: { message: "rate limited" } }.to_json },
        { status: 200, body: { candidates: [{ content: { parts: [{ text: '{"action":"final","answer":"ok"}' }] } }] }.to_json }
      )

    backend = described_class.new(model_name: model_name, api_key: api_key, max_retries: 1)
    response = backend.complete(messages: [{ role: "user", content: "hi" }], generation_config: {})

    expect(response[:text]).to include("\"answer\":\"ok\"")
    expect(a_request(:post, endpoint)).to have_been_made.twice
  end

  describe "#build_payload" do
    let(:backend) { described_class.new(model_name: model_name, api_key: api_key) }

    it "builds proper contents array with user/model roles" do
      messages = [
        { role: "system", content: "You are helpful." },
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there" },
        { role: "user", content: "How are you?" }
      ]
      payload = backend.send(:build_payload, messages: messages, generation_config: {})

      expect(payload[:systemInstruction][:parts][0][:text]).to eq("You are helpful.")
      expect(payload[:contents].length).to eq(3)
      expect(payload[:contents][0]).to eq({ role: "user", parts: [{ text: "Hello" }] })
      expect(payload[:contents][1]).to eq({ role: "model", parts: [{ text: "Hi there" }] })
      expect(payload[:contents][2]).to eq({ role: "user", parts: [{ text: "How are you?" }] })
    end

    it "omits systemInstruction when no system message" do
      messages = [{ role: "user", content: "Hello" }]
      payload = backend.send(:build_payload, messages: messages, generation_config: {})

      expect(payload).not_to have_key(:systemInstruction)
      expect(payload[:contents].length).to eq(1)
      expect(payload[:contents][0]).to eq({ role: "user", parts: [{ text: "Hello" }] })
    end

    it "normalizes generation config keys to camelCase" do
      payload = backend.send(:build_payload,
        messages: [{ role: "user", content: "hi" }],
        generation_config: { response_mime_type: "application/json", temperature: 0.5 })

      expect(payload[:generationConfig][:responseMimeType]).to eq("application/json")
      expect(payload[:generationConfig][:temperature]).to eq(0.5)
    end

    it "passes thinkingConfig through to generationConfig" do
      payload = backend.send(:build_payload,
        messages: [{ role: "user", content: "hi" }],
        generation_config: {
          temperature: 0.2,
          thinking_config: { thinkingLevel: "medium" }
        })

      expect(payload[:generationConfig][:thinkingConfig]).to eq({ thinkingLevel: "medium" })
    end
  end

  describe "#extract_text" do
    let(:backend) { described_class.new(model_name: model_name, api_key: api_key) }

    it "filters out thought parts from response" do
      parsed = {
        "candidates" => [{
          "content" => {
            "parts" => [
              { "thought" => true, "text" => "Let me think about this..." },
              { "text" => '{"action":"final","answer":"42"}' }
            ]
          }
        }]
      }

      text = backend.send(:extract_text, parsed)
      expect(text).to eq('{"action":"final","answer":"42"}')
      expect(text).not_to include("think about this")
    end
  end

  describe "#extract_usage" do
    let(:backend) { described_class.new(model_name: model_name, api_key: api_key) }

    it "includes thoughts_tokens from usageMetadata" do
      parsed = {
        "usageMetadata" => {
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "thoughtsTokenCount" => 200,
          "totalTokenCount" => 215
        }
      }

      usage = backend.send(:extract_usage, parsed)
      expect(usage[:thoughts_tokens]).to eq(200)
      expect(usage[:total_tokens]).to eq(215)
    end
  end

  describe "#stream_complete" do
    let(:sse_body) do
      chunks = [
        { candidates: [{ content: { parts: [{ text: "Hello " }] } }] },
        { candidates: [{ content: { parts: [{ text: "world" }] } }],
          usageMetadata: { promptTokenCount: 5, candidatesTokenCount: 2, totalTokenCount: 7 } }
      ]
      chunks.map { |c| "data: #{c.to_json}\n\n" }.join
    end

    it "yields text deltas and returns accumulated text with usage" do
      stub_request(:post, stream_endpoint)
        .to_return(status: 200, body: sse_body,
                   headers: { "Content-Type" => "text/event-stream" })

      backend = described_class.new(model_name: model_name, api_key: api_key)
      deltas = []
      result = backend.stream_complete(
        messages: [{ role: "user", content: "hi" }],
        generation_config: {}
      ) { |chunk, _acc| deltas << chunk }

      expect(deltas).to eq(["Hello ", "world"])
      expect(result[:text]).to eq("Hello world")
      expect(result[:usage]).to eq(prompt_tokens: 5, candidate_tokens: 2, thoughts_tokens: 0, cached_content_tokens: 0, total_tokens: 7)
    end

    it "raises BackendError on non-2xx status" do
      stub_request(:post, stream_endpoint)
        .to_return(status: 500, body: "Internal error")

      backend = described_class.new(model_name: model_name, api_key: api_key)
      expect {
        backend.stream_complete(messages: [{ role: "user", content: "hi" }], generation_config: {})
      }.to raise_error(RubyRLM::BackendError)
    end

    it "retries transient 503 stream errors and then succeeds" do
      stub_request(:post, stream_endpoint)
        .to_return(
          { status: 503, body: { error: { message: "high demand" } }.to_json, headers: { "Content-Type" => "application/json" } },
          { status: 200, body: sse_body, headers: { "Content-Type" => "text/event-stream" } }
        )

      backend = described_class.new(model_name: model_name, api_key: api_key, max_retries: 1)
      result = backend.stream_complete(messages: [{ role: "user", content: "hi" }], generation_config: {})

      expect(result[:text]).to eq("Hello world")
      expect(a_request(:post, stream_endpoint)).to have_been_made.twice
    end

    it "works without a block" do
      stub_request(:post, stream_endpoint)
        .to_return(status: 200, body: sse_body,
                   headers: { "Content-Type" => "text/event-stream" })

      backend = described_class.new(model_name: model_name, api_key: api_key)
      result = backend.stream_complete(
        messages: [{ role: "user", content: "hi" }],
        generation_config: {}
      )

      expect(result[:text]).to eq("Hello world")
    end
  end
end
