require "spec_helper"

RSpec.describe RubyRLM::Repl::DockerRepl do
  class FakeSocket
    attr_reader :writes

    def initialize(messages:)
      @lines = messages.map { |message| "#{JSON.generate(message)}\n" }
      @writes = []
      @closed = false
    end

    def gets
      @lines.shift
    end

    def write(data)
      @writes << data
      data.bytesize
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  let(:manager) do
    instance_double(
      RubyRLM::Repl::DockerRepl::ContainerManager,
      start!: true,
      stop!: true,
      running?: false,
      mapped_port: 44_321
    )
  end

  let(:llm_query_proc) { ->(_prompt, model_name: nil) { "noop-#{model_name}" } }

  def build_repl(timeout_seconds: 2)
    described_class.new(context: { message: "hello" }, llm_query_proc: llm_query_proc, timeout_seconds: timeout_seconds)
  end

  before do
    allow(RubyRLM::Repl::DockerRepl::ContainerManager).to receive(:new).and_return(manager)
  end

  it "executes code and parses execute_result payload" do
    socket = FakeSocket.new(messages: [{ type: "init_ok" }, { type: "execute_result", ok: true, stdout: "hello\n", stderr: "", value_preview: "\"ok\"" }])
    allow(TCPSocket).to receive(:new).and_return(socket)

    repl = build_repl
    result = repl.execute("puts 'hello'")

    expect(result.ok).to be(true)
    expect(result.stdout).to eq("hello\n")
    expect(result.error_message).to be_nil
    parsed_messages = socket.writes.map { |raw| JSON.parse(raw, symbolize_names: true) }
    expect(parsed_messages.map { |msg| msg[:type] }).to eq(%w[init execute])
  end

  it "passes runtime model name in init payload" do
    socket = FakeSocket.new(messages: [{ type: "init_ok" }, { type: "execute_result", ok: true, stdout: "", stderr: "" }])
    allow(TCPSocket).to receive(:new).and_return(socket)

    repl = described_class.new(context: {}, llm_query_proc: llm_query_proc, timeout_seconds: 2, model_name: "gemini-test")
    result = repl.execute("1 + 1")

    expect(result.ok).to be(true)
    init_payload = JSON.parse(socket.writes.first, symbolize_names: true)
    expect(init_payload.dig(:runtime, :default_model_name)).to eq("gemini-test")
  end

  it "returns timeout results" do
    socket = instance_double(TCPSocket)
    allow(socket).to receive(:gets) { sleep 0.2 }
    allow(socket).to receive(:write).and_return(1)
    allow(socket).to receive(:closed?).and_return(false)
    allow(socket).to receive(:close)
    allow(TCPSocket).to receive(:new).and_return(socket)

    repl = build_repl(timeout_seconds: 0.05)
    result = repl.execute("sleep 1")

    expect(result.ok).to be(false)
    expect(result.error_class).to eq("Timeout::Error")
  end

  it "returns connection failures as error execution results" do
    allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)
    repl = build_repl

    result = repl.execute("puts 1")
    expect(result.ok).to be(false)
    expect(result.error_class).to eq("Errno::ECONNREFUSED")
  end

  it "shutdown closes socket and stops container" do
    socket = FakeSocket.new(messages: [{ type: "init_ok" }, { type: "execute_result", ok: true, stdout: "", stderr: "" }])
    allow(TCPSocket).to receive(:new).and_return(socket)
    repl = build_repl
    repl.execute("1 + 1")

    repl.shutdown

    expect(manager).to have_received(:stop!)
    expect(socket).to be_closed
  end
end
