require "spec_helper"

RSpec.describe RubyRLM::Client do
  class QueueBackend
    attr_reader :calls

    def initialize(responses)
      @responses = responses.dup
      @calls = []
    end

    def complete(messages:, generation_config: {})
      @calls << { messages: messages, generation_config: generation_config }
      response = @responses.shift
      raise "No queued backend response available" unless response

      {
        text: response.fetch(:text),
        usage: response.fetch(:usage, { prompt_tokens: 1, candidate_tokens: 1, total_tokens: 2 }),
        raw: response.fetch(:raw, {}),
        latency_s: response.fetch(:latency_s, 0.01)
      }
    end
  end

  it "runs exec then final loop" do
    backend = QueueBackend.new(
      [
        { text: '{"action":"exec","code":"puts context"}' },
        { text: '{"action":"final","answer":"done"}' }
      ]
    )
    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend,
      max_iterations: 5
    )

    result = client.completion(prompt: "hello")

    expect(result.response).to eq("done")
    expect(result.metadata[:iterations].length).to eq(2)
    expect(result.metadata[:iterations].first[:action]).to eq("exec")
    expect(result.metadata[:iterations].last[:action]).to eq("final")
  end

  it "recovers once from malformed action JSON" do
    backend = QueueBackend.new(
      [
        { text: "not valid json" },
        { text: '{"action":"final","answer":"recovered"}' }
      ]
    )
    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend
    )

    result = client.completion(prompt: "hello")

    expect(result.response).to eq("recovered")
    expect(result.metadata[:iterations].first[:repaired]).to be(true)
    expect(backend.calls.length).to eq(2)
  end

  it "forces final answer after max iterations" do
    backend = QueueBackend.new(
      [
        { text: '{"action":"exec","code":"1 + 1"}' },
        { text: '{"action":"final","answer":"forced"}' }
      ]
    )
    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend,
      max_iterations: 1
    )

    result = client.completion(prompt: "hello")

    expect(result.response).to eq("forced")
    expect(result.metadata[:forced_final]).to be(true)
    expect(result.metadata[:iterations].last[:action]).to eq("forced_final")
  end

  it "logs parent-child run relationship for recursive llm_query" do
    shared_backend = QueueBackend.new(
      [
        { text: '{"action":"exec","code":"@sub = llm_query(\"What is 2+2?\")"}' },
        { text: '{"action":"final","answer":"4"}' },
        { text: '{"action":"final","answer":"root-final"}' }
      ]
    )
    logger = RubyRLM::Logger::JsonlLogger.new(log_dir: nil)

    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      max_depth: 1,
      logger: logger,
      backend_client: shared_backend
    )
    result = client.completion(prompt: "compute")

    expect(result.response).to eq("root-final")
    starts = logger.events.select { |event| event[:type] == "run_start" }
    expect(starts.length).to eq(2)

    root_start = starts.find { |event| event[:depth] == 0 }
    child_start = starts.find { |event| event[:depth] == 1 }
    expect(child_start[:parent_run_id]).to eq(root_start[:run_id])
  end

  it "shares backend_client with child when model matches" do
    shared_backend = QueueBackend.new(
      [
        { text: '{"action":"exec","code":"@sub = llm_query(\"sub-question\")"}' },
        { text: '{"action":"final","answer":"child-done"}' },
        { text: '{"action":"final","answer":"root-done"}' }
      ]
    )

    expect(RubyRLM::Backends::GeminiRest).not_to receive(:new)

    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: shared_backend,
      max_depth: 1
    )
    result = client.completion(prompt: "hello")
    expect(result.response).to eq("root-done")
    expect(shared_backend.calls.length).to eq(3)
  end

  it "creates new backend_client for child when model differs" do
    root_backend = QueueBackend.new(
      [
        { text: '{"action":"exec","code":"@sub = llm_query(\"sub\", model_name: \"gemini-2.5-pro\")"}' },
        { text: '{"action":"final","answer":"root-done"}' }
      ]
    )
    child_backend = QueueBackend.new(
      [
        { text: '{"action":"final","answer":"child-done"}' }
      ]
    )

    allow(RubyRLM::Backends::GeminiRest).to receive(:new)
      .with(hash_including(model_name: "gemini-2.5-pro"))
      .and_return(child_backend)

    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: root_backend,
      max_depth: 1
    )
    result = client.completion(prompt: "hello")
    expect(result.response).to eq("root-done")
    expect(RubyRLM::Backends::GeminiRest).to have_received(:new).with(hash_including(model_name: "gemini-2.5-pro"))
  end

  it "uses direct model call when recursion depth limit is reached" do
    backend = QueueBackend.new(
      [
        { text: "direct-sub-answer" }
      ]
    )
    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend,
      max_depth: 0
    )

    answer = client.send(:llm_query, "sub-question")
    expect(answer).to eq("direct-sub-answer")
    expect(backend.calls.first[:generation_config][:response_mime_type]).to eq("text/plain")
  end

  it "treats plain JSON object model responses as final without repair call" do
    backend = QueueBackend.new(
      [
        { text: '{"root_cause":"db deadlock","confidence":0.99}' }
      ]
    )
    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend
    )

    result = client.completion(prompt: "analyze")
    expect(result.response).to include("\"root_cause\": \"db deadlock\"")
    expect(backend.calls.length).to eq(1)
  end

  it "sends only summarized context to model messages" do
    unique_marker = "UNIQUE_MARKER_DEEP_IN_CONTEXT"
    context = {
      task: "analyze",
      logs: Array.new(10) { |i| i == 9 ? unique_marker : "line-#{i}" }
    }
    backend = QueueBackend.new(
      [
        { text: '{"action":"final","answer":"ok"}' }
      ]
    )
    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend
    )

    client.completion(prompt: context)

    user_message = backend.calls.first[:messages].find { |message| message[:role] == "user" }[:content]
    expect(user_message).to include("Context summary")
    expect(user_message).to include("Array(size=10")
    expect(user_message).not_to include(unique_marker)
  end

  it "logs backend_retry events from streaming backend" do
    backend = Class.new do
      def stream_complete(messages:, generation_config:, on_retry: nil)
        on_retry&.call(
          provider: "gemini",
          mode: "stream",
          attempt: 1,
          next_attempt: 2,
          max_retries: 2,
          backoff_seconds: 0.4,
          status_code: 503,
          error_message: "temporary capacity issue"
        )
        text = '{"action":"final","answer":"ok"}'
        yield text, text if block_given?
        {
          text: text,
          usage: { prompt_tokens: 1, candidate_tokens: 1, total_tokens: 2 },
          raw: {},
          latency_s: 0.01
        }
      end

      def complete(messages:, generation_config: {})
        raise "unexpected blocking path"
      end
    end.new

    logger = RubyRLM::Logger::JsonlLogger.new(log_dir: nil)
    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend,
      logger: logger,
      streaming: true
    )

    result = client.completion(prompt: "hello")
    expect(result.response).to eq("ok")

    retry_event = logger.events.find { |event| event[:type] == "backend_retry" }
    expect(retry_event).not_to be_nil
    expect(retry_event[:mode]).to eq("stream")
    expect(retry_event[:status_code]).to eq(503)
  end

  it "bounds iterative message history" do
    responses = Array.new(6) { { text: '{"action":"exec","code":"1 + 1"}' } }
    responses << { text: '{"action":"final","answer":"done"}' }
    backend = QueueBackend.new(responses)

    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend,
      max_iterations: 10,
      max_messages: 6
    )

    result = client.completion(prompt: "hello")
    expect(result.response).to eq("done")
    expect(backend.calls.last[:messages].length).to be <= 6
    expect(backend.calls.last[:messages][0][:role]).to eq("system")
    expect(backend.calls.last[:messages][1][:role]).to eq("user")
  end

  it "uses DockerRepl when environment is docker and shuts it down" do
    backend = QueueBackend.new(
      [
        { text: '{"action":"exec","code":"puts 1"}' },
        { text: '{"action":"final","answer":"ok"}' }
      ]
    )
    fake_repl = instance_double(
      RubyRLM::Repl::DockerRepl,
      execute: RubyRLM::Repl::ExecutionResult.new(ok: true, stdout: "1\n", stderr: "", value_preview: "1"),
      shutdown: nil
    )
    allow(RubyRLM::Repl::DockerRepl).to receive(:new).and_return(fake_repl)

    client = described_class.new(
      model_name: "gemini-2.5-flash",
      api_key: "test-key",
      backend_client: backend,
      environment: "docker"
    )
    result = client.completion(prompt: "hello")

    expect(result.response).to eq("ok")
    expect(RubyRLM::Repl::DockerRepl).to have_received(:new)
    expect(fake_repl).to have_received(:shutdown)
  end

  it "raises ConfigurationError for unsupported environment" do
    expect {
      described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        environment: "unsupported-env"
      )
    }.to raise_error(RubyRLM::ConfigurationError, /Unsupported environment/)
  end

  it "accepts docker secret environment options" do
    expect {
      described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        environment: "docker",
        environment_options: {
          gemini_api_key_secret: "gemini_api_key",
          gemini_api_key_secret_path: "/tmp/secret.txt"
        }
      )
    }.not_to raise_error
  end

  it "rejects empty docker secret option values" do
    expect {
      described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        environment: "docker",
        environment_options: { gemini_api_key_secret: "" }
      )
    }.to raise_error(RubyRLM::ConfigurationError, /gemini_api_key_secret/)
  end
end
