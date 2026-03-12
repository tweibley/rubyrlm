module RubyRLM
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class BackendError < Error; end
  class ParseError < Error; end
  class ReplError < Error; end
  class TimeoutError < ReplError; end
  class CodeValidationError < ReplError; end
  class CompactionError < Error; end
end
