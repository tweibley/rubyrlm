require "spec_helper"
require "timeout"
require "tmpdir"

require_relative "../lib/rubyrlm/web/services/streaming_logger"
require_relative "../lib/rubyrlm/web/services/query_service"

RSpec.describe RubyRLM::Web::Services::QueryService do
  it "reaps finished runs when no stream consumer attaches" do
    service = described_class.new(
      log_dir: Dir.mktmpdir("rubyrlm-query-spec"),
      cleanup_ttl_seconds: 0.05,
      cleanup_interval_seconds: 0.01
    )
    result = instance_double(RubyRLM::CompletionResult, response: "done", execution_time: 0.01)
    fake_client = instance_double(RubyRLM::Client, completion: result)
    allow(RubyRLM::Client).to receive(:new).and_return(fake_client)

    run_id = service.start_run(prompt: "orphan")
    sleep 0.2

    active_runs = service.instance_variable_get(:@active_runs)
    expect(active_runs).not_to have_key(run_id)
  end

  it "emits run_error when client initialization fails" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    allow(RubyRLM::Client).to receive(:new).and_raise(ArgumentError, "init boom")

    run_id = service.start_run(prompt: "hello")
    events = service.stream_events(run_id)

    first = Timeout.timeout(2) { events.next }
    expect(first[:type]).to eq("run_error")
    expect(first[:error]).to include("init boom")
    expect { events.next }.to raise_error(StopIteration)
  end

  it "does not terminate stream on run_end before run_complete" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    broadcaster = RubyRLM::Web::Services::EventBroadcaster.new
    worker = Thread.new { sleep 1 }
    run_id = "test-run-id"

    mutex = service.instance_variable_get(:@mutex)
    active_runs = service.instance_variable_get(:@active_runs)
    mutex.synchronize do
      active_runs[run_id] = { thread: worker, broadcaster: broadcaster, terminal: false, terminal_at: nil }
    end

    events = service.stream_events(run_id)
    broadcaster.broadcast({ type: "run_end" })
    broadcaster.broadcast({ type: "run_complete", response: "ok" })
    first = Timeout.timeout(2) { events.next }
    second = Timeout.timeout(2) { events.next }

    expect(first[:type]).to eq("run_end")
    expect(second[:type]).to eq("run_complete")
    expect { events.next }.to raise_error(StopIteration)
  ensure
    worker&.kill
  end

  it "appends continuation into existing session id when not forking" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    result = instance_double(RubyRLM::CompletionResult, response: "done", execution_time: 0.12)
    captured = nil
    fake_client = instance_double(RubyRLM::Client, completion: result)

    allow(RubyRLM::Client).to receive(:new) do |**kwargs|
      captured = kwargs
      fake_client
    end

    request_id = service.start_run(prompt: "continue", session_id: "existing_run_123", fork: false)
    events = service.stream_events(request_id)
    complete = Timeout.timeout(2) { events.next }

    expect(captured[:run_id]).to eq("existing_run_123")
    expect(captured[:run_metadata]).to include(continuation_mode: "append", source_session_id: "existing_run_123")
    expect(complete[:type]).to eq("run_complete")
    expect(complete[:session_id]).to eq("existing_run_123")
  end

  it "maps thinking_level into client generation_config" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    result = instance_double(RubyRLM::CompletionResult, response: "done", execution_time: 0.12)
    captured = nil
    fake_client = instance_double(RubyRLM::Client, completion: result)

    allow(RubyRLM::Client).to receive(:new) do |**kwargs|
      captured = kwargs
      fake_client
    end

    request_id = service.start_run(prompt: "think", thinking_level: "medium")
    events = service.stream_events(request_id)
    complete = Timeout.timeout(2) { events.next }

    expect(complete[:type]).to eq("run_complete")
    expect(captured[:generation_config]).to include(response_mime_type: "application/json", temperature: 0.5)
    expect(captured[:generation_config][:thinking_config]).to eq({ thinkingLevel: "medium" })
  end

  it "forks into a new session id when fork is true" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    result = instance_double(RubyRLM::CompletionResult, response: "done", execution_time: 0.12)
    captured = nil
    fake_client = instance_double(RubyRLM::Client, completion: result)

    allow(RubyRLM::Client).to receive(:new) do |**kwargs|
      captured = kwargs
      fake_client
    end

    request_id = service.start_run(prompt: "fork", session_id: "existing_run_123", fork: true)
    events = service.stream_events(request_id)
    complete = Timeout.timeout(2) { events.next }

    expect(captured[:run_id]).to eq(request_id)
    expect(captured[:run_metadata]).to include(continuation_mode: "fork", source_session_id: "existing_run_123")
    expect(complete[:type]).to eq("run_complete")
    expect(complete[:session_id]).to eq(request_id)
  end

  it "rejects invalid session id format" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    expect {
      service.start_run(prompt: "x", session_id: "../bad", fork: false)
    }.to raise_error(ArgumentError, /Invalid session_id format/)
  end

  it "emits run_error when completion raises a ScriptError" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    fake_client = instance_double(RubyRLM::Client)
    allow(fake_client).to receive(:completion).and_raise(LoadError, "cannot load such file -- csv")
    allow(RubyRLM::Client).to receive(:new).and_return(fake_client)

    run_id = service.start_run(prompt: "trigger load error")
    events = service.stream_events(run_id)
    first = Timeout.timeout(2) { events.next }

    expect(first[:type]).to eq("run_error")
    expect(first[:error]).to include("cannot load such file -- csv")
    expect { events.next }.to raise_error(StopIteration)
  end

  it "emits run_error when worker exits without terminal queue event" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    broadcaster = RubyRLM::Web::Services::EventBroadcaster.new
    worker = Thread.new {}
    worker.report_on_exception = false
    run_id = "abnormal-worker-run"

    mutex = service.instance_variable_get(:@mutex)
    active_runs = service.instance_variable_get(:@active_runs)
    mutex.synchronize do
      active_runs[run_id] = { thread: worker, broadcaster: broadcaster, terminal: false, terminal_at: nil }
    end

    events = service.stream_events(run_id)
    first = Timeout.timeout(2) { events.next }

    expect(first[:type]).to eq("run_error")
    expect(first[:error]).to include("Run terminated unexpectedly before completion")
    expect { events.next }.to raise_error(StopIteration)
  end

  it "broadcasts terminal events to multiple stream consumers" do
    service = described_class.new(log_dir: Dir.mktmpdir("rubyrlm-query-spec"))
    result = instance_double(RubyRLM::CompletionResult, response: "done", execution_time: 0.01)
    fake_client = instance_double(RubyRLM::Client, completion: result)
    allow(RubyRLM::Client).to receive(:new).and_return(fake_client)

    run_id = service.start_run(prompt: "shared")
    stream_a = service.stream_events(run_id)
    stream_b = service.stream_events(run_id)

    event_a = Timeout.timeout(2) { stream_a.next }
    event_b = Timeout.timeout(2) { stream_b.next }

    expect(event_a[:type]).to eq("run_complete")
    expect(event_b[:type]).to eq("run_complete")
    expect(event_a[:session_id]).to eq(event_b[:session_id])
  end
end
