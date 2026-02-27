require "spec_helper"

RSpec.describe RubyRLM::Prompts::SystemPrompt do
  it "contains strict action contract instructions" do
    prompt = described_class.build
    expect(prompt).to include('{"action":"exec","code":"<ruby code>"}')
    expect(prompt).to include('{"action":"final","answer":"<final answer text>"}')
    expect(prompt).to include("Return ONLY one JSON object per turn")
    expect(prompt).to include("Ensure `code` is a valid JSON string")
    expect(prompt).to include("escape newlines as \\n")
    expect(prompt).to include('{"action":"exec","code":"keys = context.keys\\nkeys"}')
  end

  it "documents runtime capabilities accurately" do
    prompt = described_class.build
    expect(prompt).to include("`context` contains the full task data")
    expect(prompt).to include("`llm_query(sub_prompt, model_name: nil)` is available")
    expect(prompt).to include("returns its answer as a String")
    expect(prompt).to include("last evaluated expression in your `exec` code is automatically returned as `value_preview`")
    expect(prompt).to include("both symbol and string keys are supported")
    expect(prompt).to include("`fetch(url, headers: {})` performs HTTP GET")
    expect(prompt).to include("`sh(command, timeout: 5)` runs a shell command safely")
    expect(prompt).to include("`patch_file(path, old_text, new_text)` replaces text exactly once")
    expect(prompt).to include("`grep(pattern, path: \".\")` searches with ripgrep")
    expect(prompt).to include("`chunk_text(text, max_length: 2000)` splits long text semantically")
  end

  it "documents markdown and mermaid support in final answers" do
    prompt = described_class.build
    expect(prompt).to include("Markdown is allowed inside `answer`")
    expect(prompt).to include("fenced Mermaid block inside `answer`")
    expect(prompt).to include("Keep Mermaid syntax valid and concise")
  end

  it "includes environment-specific runtime guidance for docker mode" do
    prompt = described_class.build(execution_environment: "docker", environment_options: { allow_network: false })
    expect(prompt).to include("docker strict-isolation mode")
    expect(prompt).to include("`patch_file` and `grep` will fail")
    expect(prompt).to include("outbound network is disabled")
  end

  it "includes root hint when provided" do
    prompt = described_class.build(root_prompt: "Solve this precisely.")
    expect(prompt).to include("Root hint: Solve this precisely.")
  end

  it "provides strict malformed response repair prompt" do
    repair = described_class.malformed_response_repair
    expect(repair).to include("not valid action JSON")
    expect(repair).to include('{"action":"exec","code":"..."}')
    expect(repair).to include('{"action":"final","answer":"..."}')
    expect(repair).to include("Optional ```json fence is allowed")
  end

  it "provides forced final prompt guidance" do
    forced = described_class.force_final
    expect(forced).to include("iteration limit")
    expect(forced).to include('{"action":"final","answer":"..."}')
  end
end
