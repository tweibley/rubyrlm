module RubyRLM
  module Repl
    class ExecutionResult
      attr_reader :ok, :stdout, :stderr, :value_preview, :error_class, :error_message, :backtrace_excerpt, :warnings

      def initialize(
        ok:,
        stdout:,
        stderr:,
        value_preview: nil,
        error_class: nil,
        error_message: nil,
        backtrace_excerpt: [],
        warnings: []
      )
        @ok = ok
        @stdout = stdout
        @stderr = stderr
        @value_preview = value_preview
        @error_class = error_class
        @error_message = error_message
        @backtrace_excerpt = backtrace_excerpt
        @warnings = warnings
      end

      def to_h
        h = {
          ok: @ok,
          stdout: @stdout,
          stderr: @stderr,
          value_preview: @value_preview,
          error_class: @error_class,
          error_message: @error_message,
          backtrace_excerpt: @backtrace_excerpt
        }
        h[:warnings] = @warnings unless @warnings.empty?
        h
      end
    end
  end
end
