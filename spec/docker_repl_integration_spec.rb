require "spec_helper"
require "open3"
require "securerandom"

RSpec.describe RubyRLM::Repl::DockerRepl, :docker do
  before(:all) do
    skip "Set DOCKER_TESTS=1 to run docker integration tests" unless ENV["DOCKER_TESTS"]

    stdout, stderr, status = Open3.capture3(
      "docker", "build",
      "-t", "rubyrlm/repl:latest",
      "-f", "docker/Dockerfile.repl",
      "docker/"
    )
    raise "Docker image build failed: #{stderr}\n#{stdout}" unless status.success?
  end

  let(:llm_query_proc) { ->(prompt, model_name: nil) { "unused-#{prompt}-#{model_name}" } }

  it "runs code in docker and captures output" do
    repl = described_class.new(context: { msg: "hello" }, llm_query_proc: llm_query_proc, timeout_seconds: 5, allow_network: true)
    result = repl.execute("puts context[:msg]")
    repl.shutdown

    expect(result.ok).to be(true)
    expect(result.stdout).to include("hello")
  end

  it "supports in-container llm_query when GEMINI_API_KEY is present" do
    skip "Set DOCKER_TESTS_WITH_GEMINI=1 and GEMINI_API_KEY to run llm_query integration" unless ENV["DOCKER_TESTS_WITH_GEMINI"] == "1"
    skip "Set GEMINI_API_KEY for llm_query integration" if ENV["GEMINI_API_KEY"].to_s.strip.empty?

    repl = described_class.new(context: { value: 7 }, llm_query_proc: llm_query_proc, timeout_seconds: 5, allow_network: true)
    result = repl.execute("puts llm_query('Reply with exactly: integration-ok')")
    repl.shutdown

    expect(result.ok).to be(true)
    expect(result.stdout).to include("integration-ok")
  end

  it "fails patch_file in strict docker mode" do
    repl = described_class.new(context: {}, llm_query_proc: llm_query_proc, timeout_seconds: 5, allow_network: false)
    result = repl.execute('patch_file("README.md", "A", "B")')
    repl.shutdown

    expect(result.ok).to be(false)
    expect(result.error_message).to include("disabled in strict Docker mode")
  end

  it "blocks fetch when allow_network is false" do
    repl = described_class.new(context: {}, llm_query_proc: llm_query_proc, timeout_seconds: 5, allow_network: false)
    result = repl.execute('fetch("https://example.com")')
    repl.shutdown

    expect(result.ok).to be(false)
    expect(result.error_message).to include("Docker network access is disabled")
  end

  it "returns structured runtime errors" do
    repl = described_class.new(context: {}, llm_query_proc: llm_query_proc, timeout_seconds: 5, allow_network: true)
    result = repl.execute("raise 'boom'")
    repl.shutdown

    expect(result.ok).to be(false)
    expect(result.error_class).to eq("RuntimeError")
    expect(result.error_message).to eq("boom")
  end
end
