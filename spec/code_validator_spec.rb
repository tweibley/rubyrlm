require "spec_helper"

RSpec.describe RubyRLM::Repl::CodeValidator do
  describe ".validate!" do
    it "accepts valid Ruby code and returns empty warnings" do
      warnings = described_class.validate!("x = 1 + 2\nputs x")
      expect(warnings).to be_an(Array)
    end

    it "raises CodeValidationError on syntax errors" do
      expect {
        described_class.validate!("def foo(")
      }.to raise_error(RubyRLM::CodeValidationError, /Syntax error/)
    end

    it "raises CodeValidationError on empty code" do
      expect {
        described_class.validate!("")
      }.to raise_error(RubyRLM::CodeValidationError, /Empty code/)
    end

    it "raises CodeValidationError on whitespace-only code" do
      expect {
        described_class.validate!("   \n  ")
      }.to raise_error(RubyRLM::CodeValidationError, /Empty code/)
    end

    it "detects system() as a dangerous call" do
      warnings = described_class.validate!('system "ls"')
      expect(warnings).to include(a_string_matching(/system/))
    end

    it "detects exec() as a dangerous call" do
      warnings = described_class.validate!('exec "bash"')
      expect(warnings).to include(a_string_matching(/exec/))
    end

    it "detects File.delete as a dangerous call" do
      warnings = described_class.validate!('File.delete("x.txt")')
      expect(warnings).to include(a_string_matching(/File\.delete/))
    end

    it "detects Kernel.exit as a dangerous call" do
      warnings = described_class.validate!("Kernel.exit(1)")
      expect(warnings).to include(a_string_matching(/Kernel\.exit/))
    end

    it "returns no warnings for safe code" do
      warnings = described_class.validate!("result = [1, 2, 3].map { |x| x * 2 }\nputs result.inspect")
      expect(warnings).to be_empty
    end

    it "handles multi-line code with mixed safe and dangerous calls" do
      code = <<~RUBY
        data = context[:items]
        processed = data.map { |item| item.to_s }
        system "echo done"
        processed
      RUBY
      warnings = described_class.validate!(code)
      expect(warnings.length).to eq(1)
      expect(warnings.first).to match(/system/)
    end
  end
end
