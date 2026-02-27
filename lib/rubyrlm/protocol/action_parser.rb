require "json"

module RubyRLM
  module Protocol
    class ActionParser
      def parse(raw_text)
        parsed = parse_json(raw_text)
        unless parsed.is_a?(Hash)
          return { action: "final", answer: jsonish_to_text(parsed) }
        end

        action = parsed.fetch("action") { parsed.fetch(:action, nil) }
        case action
        when "exec"
          code = parsed.fetch("code") { parsed.fetch(:code, nil) }
          raise ParseError, "Missing code for exec action" if blank?(code)

          { action: "exec", code: code.to_s }
        when "final"
          answer = parsed.fetch("answer") { parsed.fetch(:answer, nil) }
          raise ParseError, "Missing answer for final action" if blank?(answer)

          { action: "final", answer: answer.to_s }
        when nil
          # If the model returns a plain JSON object, treat it as final answer payload.
          { action: "final", answer: JSON.pretty_generate(parsed) }
        else
          raise ParseError, "Unknown action: #{action.inspect}"
        end
      end

      private

      def parse_json(raw_text)
        candidates(raw_text).each do |candidate|
          begin
            return JSON.parse(candidate)
          rescue JSON::ParserError
            next
          end
        end

        raise ParseError, "Model response is not valid JSON"
      end

      def candidates(raw_text)
        text = raw_text.to_s.strip
        list = [text]

        stripped = strip_markdown_fence(text)
        list << stripped if stripped

        extracted = extract_json_object(text)
        list << extracted if extracted

        list.compact.uniq
      end

      def strip_markdown_fence(text)
        return nil unless text.start_with?("```") && text.end_with?("```")

        text.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "")
      end

      def extract_json_object(text)
        start_idx = text.index("{")
        end_idx = text.rindex("}")
        return nil unless start_idx && end_idx && end_idx > start_idx

        text[start_idx..end_idx]
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def jsonish_to_text(value)
        return value if value.is_a?(String)

        JSON.generate(value)
      end
    end
  end
end
