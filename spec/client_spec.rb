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
      max_messages: 6,
      compaction: false
    )

    result = client.completion(prompt: "hello")
    expect(result.response).to eq("done")
    expect(backend.calls.last[:messages].length).to be <= 6
    expect(backend.calls.last[:messages][0][:role]).to eq("system")
    expect(backend.calls.last[:messages][1][:role]).to eq("user")
  end

  context "compaction" do
    it "fires compaction and records event in metadata" do
      # max_messages: 6, threshold: 0.5 → trigger at ceil(6 * 0.5) = 3
      # initial_messages = 2, after first exec+feedback = 4 → triggers compaction
      responses = [
        { text: '{"action":"exec","code":"1 + 1"}' },
        { text: '{"action":"final","answer":"done"}' }
      ]
      main_backend = QueueBackend.new(responses)
      compaction_backend = QueueBackend.new([
        { text: "Summary: computed 1+1 = 2." }
      ])

      allow(RubyRLM::Backends::GeminiRest).to receive(:new)
        .with(hash_including(model_name: "gemini-2.0-flash-lite"))
        .and_return(compaction_backend)

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: main_backend,
        max_messages: 6,
        compaction: true,
        compaction_threshold: 0.5
      )
      result = client.completion(prompt: "hello")

      expect(result.response).to eq("done")
      expect(result.metadata[:compaction_events]).not_to be_empty
      event = result.metadata[:compaction_events].first
      expect(event[:model]).to eq("gemini-2.0-flash-lite")
      expect(event[:messages_before]).to be >= 4
      expect(event[:messages_after]).to eq(3)
    end

    it "does not compact when disabled" do
      responses = [
        { text: '{"action":"exec","code":"1 + 1"}' },
        { text: '{"action":"final","answer":"done"}' }
      ]
      backend = QueueBackend.new(responses)

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        compaction: false
      )
      result = client.completion(prompt: "hello")

      expect(result.response).to eq("done")
      expect(result.metadata[:compaction_events]).to be_empty
    end

    it "falls back to truncation on compaction error" do
      responses = Array.new(4) { { text: '{"action":"exec","code":"1 + 1"}' } }
      responses << { text: '{"action":"final","answer":"done"}' }
      main_backend = QueueBackend.new(responses)

      failing_backend = Class.new do
        def complete(messages:, generation_config: {})
          raise RubyRLM::BackendError, "network timeout"
        end
      end.new

      allow(RubyRLM::Backends::GeminiRest).to receive(:new)
        .with(hash_including(model_name: "gemini-2.0-flash-lite"))
        .and_return(failing_backend)

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: main_backend,
        max_messages: 6,
        compaction: true,
        compaction_threshold: 0.5
      )
      result = client.completion(prompt: "hello")

      expect(result.response).to eq("done")
      expect(result.metadata[:compaction_events]).to be_empty
    end

    it "inherits compaction: false in child clients" do
      shared_backend = QueueBackend.new([
        { text: '{"action":"exec","code":"@sub = llm_query(\"What is 2+2?\")"}' },
        # Child responses
        { text: '{"action":"exec","code":"2 + 2"}' },
        { text: '{"action":"final","answer":"4"}' },
        # Root final
        { text: '{"action":"final","answer":"root-done"}' }
      ])

      # Compaction backend should never be instantiated when compaction is disabled
      expect(RubyRLM::Backends::GeminiRest).not_to receive(:new)
        .with(hash_including(model_name: "gemini-2.0-flash-lite"))

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: shared_backend,
        max_depth: 1,
        compaction: false
      )
      result = client.completion(prompt: "hello")
      expect(result.response).to eq("root-done")
      expect(result.metadata[:compaction_events]).to be_empty
    end

    it "raises ConfigurationError for invalid compaction_threshold" do
      expect {
        described_class.new(
          model_name: "gemini-2.5-flash",
          api_key: "test-key",
          compaction_threshold: 0.0
        )
      }.to raise_error(RubyRLM::ConfigurationError, /compaction_threshold/)

      expect {
        described_class.new(
          model_name: "gemini-2.5-flash",
          api_key: "test-key",
          compaction_threshold: 1.5
        )
      }.to raise_error(RubyRLM::ConfigurationError, /compaction_threshold/)
    end
  end

  context "budget guards" do
    it "surfaces budget stats in metadata" do
      backend = QueueBackend.new([
        { text: '{"action":"final","answer":"done"}', usage: { prompt_tokens: 100, candidate_tokens: 50, total_tokens: 150 } }
      ])
      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        budget: { max_subcalls: 10, max_cost_usd: 1.0 }
      )
      result = client.completion(prompt: "hello")
      expect(result.metadata[:budget]).to be_a(Hash)
      expect(result.metadata[:budget][:limits]).to eq({ max_subcalls: 10, max_cost_usd: 1.0 })
      expect(result.metadata[:budget][:total_tokens]).to eq 150
    end

    it "stops subcalls when max_subcalls exceeded" do
      backend = QueueBackend.new([
        { text: '{"action":"exec","code":"r1 = llm_query(\"q1\"); r2 = llm_query(\"q2\"); r3 = llm_query(\"q3\")"}' },
        { text: "answer-1" },
        { text: "answer-2" },
        { text: '{"action":"final","answer":"done"}' }
      ])
      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        max_depth: 0,
        budget: { max_subcalls: 2 }
      )
      result = client.completion(prompt: "hello")
      expect(result.response).to eq("done")
      # 3 attempts: 2 succeeded, 3rd was blocked but still counted as an attempt
      expect(result.metadata[:budget][:subcalls]).to eq 3
    end

    it "returns CompletionResult when budget is exceeded in main loop" do
      # gemini-2.5-flash: input=$0.15/1M, output=$0.60/1M
      # With 10000 prompt + 10000 candidate tokens per response:
      #   cost = (10000/1M * 0.15) + (10000/1M * 0.60) = 0.0015 + 0.006 = 0.0075
      # Set max_cost_usd to 0.001 so the first iteration's charge_budget exceeds it
      backend = QueueBackend.new([
        { text: '{"action":"exec","code":"1 + 1"}', usage: { prompt_tokens: 10_000, candidate_tokens: 10_000, total_tokens: 20_000 } },
        { text: '{"action":"exec","code":"2 + 2"}', usage: { prompt_tokens: 10_000, candidate_tokens: 10_000, total_tokens: 20_000 } },
        { text: '{"action":"final","answer":"budget-forced"}' }
      ])
      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        max_iterations: 10,
        budget: { max_cost_usd: 0.001 }
      )
      result = client.completion(prompt: "hello")
      expect(result).to be_a(RubyRLM::CompletionResult)
      expect(result.response).not_to be_nil
      expect(result.metadata).to be_a(Hash)
    end

    it "returns graceful message when budget exceeded in single-shot fallback" do
      # First call is the single-shot fallback in llm_query (max_depth: 0)
      # The response has high token counts to exceed the tiny budget
      backend = QueueBackend.new([
        { text: "fallback-answer", usage: { prompt_tokens: 10_000, candidate_tokens: 10_000, total_tokens: 20_000 } }
      ])
      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        max_depth: 0,
        budget: { max_cost_usd: 0.0001 }
      )

      answer = client.send(:llm_query, "sub-question")
      expect(answer).to be_a(String)
      expect(answer).to include("Budget exceeded")
    end

    it "does not add budget metadata when no budget configured" do
      backend = QueueBackend.new([
        { text: '{"action":"final","answer":"done"}' }
      ])
      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend
      )
      result = client.completion(prompt: "hello")
      expect(result.metadata[:budget]).to be_nil
    end
  end

  context "cross-model routing" do
    it "routes subcalls to subcall_model by default" do
      # Use the same model name so the subcall reuses the same backend
      # and we can verify which calls were made
      backend = QueueBackend.new([
        { text: '{"action":"exec","code":"@sub = llm_query(\"sub-question\")"}' },
        { text: "flash-answer" },
        { text: '{"action":"final","answer":"root-done"}' }
      ])

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        max_depth: 0,
        subcall_model: "gemini-2.0-flash-lite"
      )

      # Stub the backend builder to return a separate backend for the subcall model
      subcall_backend = QueueBackend.new([{ text: "routed-answer" }])
      allow(client).to receive(:build_backend_client)
        .with(model_name: "gemini-2.0-flash-lite")
        .and_return(subcall_backend)

      result = client.completion(prompt: "hello")
      expect(result.response).to eq("root-done")
      expect(subcall_backend.calls.length).to eq(1)
    end

    it "allows explicit model_name to override subcall_model" do
      root_backend = QueueBackend.new([
        { text: '{"action":"exec","code":"@sub = llm_query(\"sub\", model_name: \"gemini-2.5-pro\")"}' },
        { text: '{"action":"final","answer":"root-done"}' }
      ])
      pro_backend = QueueBackend.new([
        { text: "pro-answer" }
      ])

      allow(RubyRLM::Backends::GeminiRest).to receive(:new)
        .with(hash_including(model_name: "gemini-2.5-pro"))
        .and_return(pro_backend)

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: root_backend,
        max_depth: 0,
        subcall_model: "gemini-2.0-flash-lite"
      )
      result = client.completion(prompt: "hello")
      expect(result.response).to eq("root-done")
      expect(pro_backend.calls.length).to eq(1)
    end

    it "falls back to main model when subcall_model is nil" do
      backend = QueueBackend.new([
        { text: '{"action":"exec","code":"@sub = llm_query(\"sub-question\")"}' },
        { text: "sub-answer" },
        { text: '{"action":"final","answer":"done"}' }
      ])

      expect(RubyRLM::Backends::GeminiRest).not_to receive(:new)

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        max_depth: 0
      )
      result = client.completion(prompt: "hello")
      expect(result.response).to eq("done")
      # All 3 calls went to the same backend (no new backend created)
      expect(backend.calls.length).to eq(3)
    end
  end

  context "rich subcall returns" do
    it "returns EpisodeResult with episode metadata from recursive subcalls" do
      shared_backend = QueueBackend.new([
        { text: '{"action":"exec","code":"@sub = llm_query(\"What is 2+2?\")"}' },
        # Child responses: exec then final
        { text: '{"action":"exec","code":"2 + 2"}' },
        { text: '{"action":"final","answer":"4"}' },
        # Root final
        { text: '{"action":"final","answer":"root-done"}' }
      ])

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        max_depth: 1,
        backend_client: shared_backend
      )
      result = client.completion(prompt: "compute")
      expect(result.response).to eq("root-done")

      # Verify the child iteration logged exec+final
      child_starts = result.metadata[:iterations].select { |i| i[:action] == "exec" }
      expect(child_starts).not_to be_empty
    end

    it "returns EpisodeResult that works as a String" do
      shared_backend = QueueBackend.new([
        { text: '{"action":"exec","code":"@sub = llm_query(\"q\"); puts @sub.class; puts @sub.length"}' },
        { text: '{"action":"final","answer":"child-answer"}' },
        { text: '{"action":"final","answer":"root-done"}' }
      ])

      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        max_depth: 1,
        backend_client: shared_backend
      )
      result = client.completion(prompt: "compute")
      expect(result.response).to eq("root-done")
    end

    it "returns plain string from single-shot fallback" do
      backend = QueueBackend.new([
        { text: "direct-answer" }
      ])
      client = described_class.new(
        model_name: "gemini-2.5-flash",
        api_key: "test-key",
        backend_client: backend,
        max_depth: 0
      )
      answer = client.send(:llm_query, "question")
      expect(answer).to eq("direct-answer")
      expect(answer).to be_a(String)
      expect(answer).not_to be_a(RubyRLM::EpisodeResult)
    end
  end

  it "includes model roster in system prompt" do
    prompt = RubyRLM::Prompts::SystemPrompt.build
    expect(prompt).to include("gemini-2.0-flash-lite")
    expect(prompt).to include("gemini-2.5-pro")
    expect(prompt).to include("model_name:")
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
