module RubyRLM
  module Compaction
    class MessageCompactor
      Result = Struct.new(:compacted, :summary_text, :usage, :latency_s, :messages_before, :messages_after, keyword_init: true)

      DEFAULT_COMPACTION_MODEL = "gemini-2.0-flash-lite"

      attr_reader :threshold, :compaction_model

      def initialize(enabled:, threshold:, max_messages:, backend_builder:, compaction_model: DEFAULT_COMPACTION_MODEL)
        @enabled = enabled
        @threshold = threshold.to_f
        @max_messages = max_messages.to_i
        @backend_builder = backend_builder
        @compaction_model = compaction_model.to_s
        @backend = nil
      end

      def maybe_compact!(messages)
        return Result.new(compacted: false) unless should_compact?(messages)

        compact!(messages)
      rescue StandardError => e
        raise CompactionError, "Compaction failed: #{e.message}"
      end

      private

      def should_compact?(messages)
        return false unless @enabled
        return false if @max_messages <= 3

        messages.length >= compaction_trigger_count
      end

      def compaction_trigger_count
        (@max_messages * @threshold).ceil
      end

      def compact!(messages)
        pinned = messages.slice(0, 2)
        to_compress = messages.slice(2..)
        count_before = messages.length

        return Result.new(compacted: false) if to_compress.nil? || to_compress.empty?

        summary_text, usage, latency_s = call_compaction_model(to_compress)

        summary_message = {
          role: "user",
          content: Prompts::CompactionPrompt.summary_wrapper(summary_text)
        }

        messages.replace(pinned + [summary_message])

        Result.new(
          compacted: true,
          summary_text: summary_text,
          usage: usage,
          latency_s: latency_s,
          messages_before: count_before,
          messages_after: messages.length
        )
      end

      def call_compaction_model(messages_to_summarize)
        backend = compaction_backend
        compaction_messages = [
          { role: "system", content: Prompts::CompactionPrompt.system },
          { role: "user", content: Prompts::CompactionPrompt.user(messages_to_summarize) }
        ]
        generation_config = { response_mime_type: "text/plain", temperature: 0.2 }

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = backend.complete(messages: compaction_messages, generation_config: generation_config)
        latency_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        [response.fetch(:text).to_s.strip, response[:usage], latency_s]
      end

      def compaction_backend
        @backend ||= @backend_builder.call(model_name: @compaction_model)
      end
    end
  end
end
