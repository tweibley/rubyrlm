module RubyRLM
  module Prompts
    module CompactionPrompt
      module_function

      def system
        <<~PROMPT.strip
          You are a message history summarizer for an AI agent conversation.
          Your job is to produce a concise, information-dense summary that preserves
          all facts, code snippets, execution results, errors, and decisions made.
          The summary will replace the original messages so the agent can continue
          without losing important context. Write in past-tense third person.
          Preserve all specific values, identifiers, and findings verbatim when relevant.
        PROMPT
      end

      def user(messages)
        formatted = messages.map.with_index(1) do |msg, i|
          "[#{i}] #{msg[:role].to_s.upcase}: #{msg[:content]}"
        end.join("\n\n")

        <<~PROMPT.strip
          Summarize the following agent conversation turns into a single concise context block.
          Retain all key facts, computed values, code decisions, errors, and findings.

          --- CONVERSATION TO SUMMARIZE ---
          #{formatted}
          --- END ---

          Produce the summary now:
        PROMPT
      end

      def summary_wrapper(summary_text)
        <<~TEXT.strip
          [Context summary from earlier conversation — #{summary_text.length} chars]
          #{summary_text}
          [End of summary]
        TEXT
      end
    end
  end
end
