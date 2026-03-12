require "spec_helper"

RSpec.describe RubyRLM::Repl::LocalRepl do
  def build_repl(context: "hello", timeout_seconds: 1)
    described_class.new(
      context: context,
      llm_query_proc: ->(_prompt, model_name: nil) { "noop-#{model_name}" },
      timeout_seconds: timeout_seconds
    )
  end

  it "executes code and captures stdout" do
    repl = described_class.new(
      context: "hello",
      llm_query_proc: ->(_prompt, model_name: nil) { "sub-answer-#{model_name}" },
      timeout_seconds: 1
    )

    result = repl.execute('puts context; puts llm_query("x", model_name: "m")')

    expect(result.ok).to be(true)
    expect(result.stdout).to include("hello")
    expect(result.stdout).to include("sub-answer-m")
    expect(result.error_message).to be_nil
  end

  it "returns structured runtime errors" do
    repl = described_class.new(
      context: "hello",
      llm_query_proc: ->(_prompt, model_name: nil) { "noop-#{model_name}" },
      timeout_seconds: 1
    )

    result = repl.execute("raise 'boom'")

    expect(result.ok).to be(false)
    expect(result.error_class).to eq("RuntimeError")
    expect(result.error_message).to eq("boom")
  end

  it "returns timeout errors" do
    repl = described_class.new(
      context: "hello",
      llm_query_proc: ->(_prompt, model_name: nil) { "noop-#{model_name}" },
      timeout_seconds: 0.05
    )

    result = repl.execute("sleep 1")

    expect(result.ok).to be(false)
    expect(result.error_class).to eq("Timeout::Error")
  end

  it "returns structured script errors such as LoadError" do
    repl = described_class.new(
      context: "hello",
      llm_query_proc: ->(_prompt, model_name: nil) { "noop-#{model_name}" },
      timeout_seconds: 1
    )

    result = repl.execute("require 'rubyrlm_missing_library_12345'")

    expect(result.ok).to be(false)
    expect(result.error_class).to eq("LoadError")
    expect(result.error_message).to include("cannot load such file")
  end

  it "supports both string and symbol context keys" do
    repl = described_class.new(
      context: { "logs" => ["a", "b"], nested: { "count" => 2 } },
      llm_query_proc: ->(_prompt, model_name: nil) { "noop-#{model_name}" },
      timeout_seconds: 1
    )

    result = repl.execute("puts context[:logs].length; puts context['logs'].length; puts context[:nested]['count']")

    expect(result.ok).to be(true)
    lines = result.stdout.lines.map(&:strip)
    expect(lines).to eq(%w[2 2 2])
  end

  it "fetches JSON and follows redirects" do
    stub_request(:get, "https://example.test/start")
      .to_return(status: 302, headers: { "Location" => "https://example.test/final" })
    stub_request(:get, "https://example.test/final")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: '{"ok":true,"nested":{"value":3}}'
      )

    repl = build_repl
    result = repl.execute('payload = fetch("https://example.test/start"); puts payload[:ok]; puts payload["nested"][:value]')

    expect(result.ok).to be(true)
    expect(result.stdout.lines.map(&:strip)).to eq(%w[true 3])
  end

  it "runs shell commands with structured output" do
    repl = build_repl
    result = repl.execute('res = sh("printf out; printf err 1>&2; exit 7", timeout: 2); puts [res[:stdout], res[:stderr], res[:exit_code], res[:ok], res[:timed_out]].join("|")')

    expect(result.ok).to be(true)
    expect(result.stdout.strip).to eq("out|err|7|false|false")
  end

  it "marks shell command timeouts explicitly" do
    repl = build_repl(timeout_seconds: 2)
    result = repl.execute('res = sh("sleep 1", timeout: 0.05); puts res[:timed_out]; puts res[:ok]')

    expect(result.ok).to be(true)
    expect(result.stdout.lines.map(&:strip)).to eq(%w[true false])
  end

  it "patches files only when target text appears exactly once" do
    Dir.mktmpdir do |dir|
      previous = Dir.pwd
      begin
        Dir.chdir(dir)
        File.write("sample.txt", "alpha\nTARGET\nomega\n")

        repl = build_repl
        result = repl.execute('out = patch_file("sample.txt", "TARGET", "REPLACED"); puts out[:replaced]; puts File.read("sample.txt").include?("REPLACED")')

        expect(result.ok).to be(true)
        expect(result.stdout.lines.map(&:strip)).to eq(%w[1 true])
      ensure
        Dir.chdir(previous)
      end
    end
  end

  it "raises patch_file errors for ambiguous replacements" do
    Dir.mktmpdir do |dir|
      previous = Dir.pwd
      begin
        Dir.chdir(dir)
        File.write("sample.txt", "TARGET and TARGET")

        repl = build_repl
        result = repl.execute('patch_file("sample.txt", "TARGET", "REPLACED")')

        expect(result.ok).to be(false)
        expect(result.error_message).to include("exactly once")
      ensure
        Dir.chdir(previous)
      end
    end
  end

  it "greps codebase with file and line metadata", skip: (!system("which rg > /dev/null 2>&1") && "ripgrep (rg) not installed") do
    Dir.mktmpdir do |dir|
      previous = Dir.pwd
      begin
        Dir.chdir(dir)
        File.write("a.txt", "alpha\nneedle here\nomega\n")

        repl = build_repl
        result = repl.execute('matches = grep("needle", path: "."); puts matches.length; puts matches.any? { |m| m[:path].end_with?("a.txt") && m[:line] == 2 }')

        expect(result.ok).to be(true)
        expect(result.stdout.lines.map(&:strip)).to eq(%w[1 true])
      ensure
        Dir.chdir(previous)
      end
    end
  end

  it "chunks text semantically under max length" do
    repl = build_repl
    result = repl.execute('text = "Alpha sentence. Beta sentence.\n\nGamma sentence. Delta sentence."; chunks = chunk_text(text, max_length: 30); puts chunks.length; puts chunks.all? { |chunk| chunk.length <= 30 }')

    expect(result.ok).to be(true)
    lines = result.stdout.lines.map(&:strip)
    expect(lines[0].to_i).to be > 1
    expect(lines[1]).to eq("true")
  end
end
