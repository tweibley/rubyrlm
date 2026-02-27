require "ripper"

  class CodeValidationError < StandardError; end
module RubyRLM
  module Repl
    module CodeValidator
      DANGEROUS_METHODS = %w[
        system exec fork exit exit! abort
      ].freeze

      DANGEROUS_RECEIVERS_METHODS = {
        "File" => %w[delete unlink],
        "FileUtils" => %w[rm rm_rf rm_r remove],
        "Kernel" => %w[system exec fork exit exit! abort],
        "Process" => %w[kill exit exit!]
      }.freeze

      module_function

      # Validates syntax and returns an array of warning strings.
      # Raises CodeValidationError on syntax errors.
      def validate!(code)
        source = code.to_s
        raise CodeValidationError, "Empty code block" if source.strip.empty?

        sexp = Ripper.sexp(source)
        unless sexp
          errors = collect_syntax_errors(source)
          message = errors.empty? ? "Syntax error in generated code" : "Syntax error: #{errors.first}"
          raise CodeValidationError, message
        end

        check_dangerous_calls(sexp)
      end

      # Walks the Ripper sexp tree to find potentially dangerous method calls.
      # Returns an array of warning strings (empty if none found).
      def check_dangerous_calls(sexp)
        warnings = []
        walk_sexp(sexp, warnings)
        warnings
      end

      def collect_syntax_errors(source)
        errors = []
        Ripper.lex(source).each do |_pos, type, token, _state|
          errors << token if type == :on_parse_error
        end
        errors
      end

      def walk_sexp(node, warnings)
        return unless node.is_a?(Array)

        case node[0]
        when :command
          # e.g. system "rm -rf /"
          ident = extract_ident(node[1])
          if ident && DANGEROUS_METHODS.include?(ident)
            warnings << "Potentially dangerous call: #{ident}()"
          end
        when :fcall
          ident = extract_ident(node[1])
          if ident && DANGEROUS_METHODS.include?(ident)
            warnings << "Potentially dangerous call: #{ident}()"
          end
        when :call, :command_call
          # e.g. File.delete("x") or Kernel.system("x")
          receiver = extract_ident(node[1])
          method = extract_ident(node[3])
          if receiver && method
            dangerous = DANGEROUS_RECEIVER_METHODS_FOR(receiver)
            if dangerous&.include?(method)
              warnings << "Potentially dangerous call: #{receiver}.#{method}()"
            end
          end
          # Also check bare method name in command_call form
          if method && DANGEROUS_METHODS.include?(method) && receiver.nil?
            warnings << "Potentially dangerous call: #{method}()"
          end
        end

        node.each { |child| walk_sexp(child, warnings) }
      end

      def extract_ident(node)
        return nil unless node.is_a?(Array)

        case node[0]
        when :@ident, :@const
          node[1]
        when :var_ref, :const_ref
          extract_ident(node[1])
        when :const_path_ref
          parts = []
          n = node
          while n.is_a?(Array) && n[0] == :const_path_ref
            parts.unshift(extract_ident(n[2]))
            n = n[1]
          end
          parts.unshift(extract_ident(n))
          parts.compact.join("::")
        else
          nil
        end
      end

      def DANGEROUS_RECEIVER_METHODS_FOR(receiver)
        DANGEROUS_RECEIVERS_METHODS[receiver]
      end
    end
  end
end
