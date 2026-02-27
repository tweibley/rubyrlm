require "spec_helper"

RSpec.describe RubyRLM::Protocol::ActionParser do
  subject(:parser) { described_class.new }

  it "parses exec actions" do
    result = parser.parse('{"action":"exec","code":"puts 1"}')
    expect(result).to eq(action: "exec", code: "puts 1")
  end

  it "parses fenced final actions" do
    payload = <<~TEXT
      ```json
      {"action":"final","answer":"done"}
      ```
    TEXT
    result = parser.parse(payload)
    expect(result).to eq(action: "final", answer: "done")
  end

  it "treats plain JSON objects as implicit final answers" do
    result = parser.parse('{"root_cause":"db deadlock","confidence":0.92}')
    expect(result[:action]).to eq("final")
    expect(result[:answer]).to include("\"root_cause\": \"db deadlock\"")
  end

  it "raises ParseError for invalid payloads" do
    expect { parser.parse("not-json") }.to raise_error(RubyRLM::ParseError)
  end
end
