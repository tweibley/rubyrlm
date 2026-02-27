require "json"
require "net/http"
require "uri"

module RubyRLM
  module Backends
    class GeminiRest < Base
      DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com"

      def initialize(
        model_name:,
        api_key: ENV["GEMINI_API_KEY"],
        base_url: DEFAULT_BASE_URL,
        open_timeout: 10,
        read_timeout: 60,
        max_retries: 2
      )
        @model_name = model_name
        @api_key = api_key
        @base_url = base_url
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_retries = max_retries
      end

      def complete(messages:, generation_config: {}, on_retry: nil)
        ensure_config!
        body = build_payload(messages: messages, generation_config: generation_config)
        started = monotonic_now
        attempts = 0

        begin
          attempts += 1
          response = post_json(uri, body)
          parsed = parse_response(response)
          latency_s = monotonic_now - started
          {
            text: extract_text(parsed),
            usage: extract_usage(parsed),
            raw: parsed,
            latency_s: latency_s
          }
        rescue BackendError => e
          raise e unless retriable_error?(e) && attempts <= @max_retries

          backoff = backoff_seconds(attempts)
          notify_retry(on_retry: on_retry, mode: "complete", attempt: attempts, backoff_seconds: backoff, error: e)
          sleep(backoff)
          retry
        rescue StandardError => e
          raise BackendError, "Gemini request failed: #{e.class}: #{e.message}" unless attempts <= @max_retries

          wrapped = BackendError.new("Gemini request failed: #{e.class}: #{e.message}")
          backoff = backoff_seconds(attempts)
          notify_retry(on_retry: on_retry, mode: "complete", attempt: attempts, backoff_seconds: backoff, error: wrapped)
          sleep(backoff)
          retry
        end
      end

      def stream_complete(messages:, generation_config: {}, on_retry: nil)
        ensure_config!
        body = build_payload(messages: messages, generation_config: generation_config)
        started = monotonic_now
        attempts = 0
        emitted_any = false

        begin
          attempts += 1
          accumulated = +""
          last_parsed = nil
          last_usage = nil

          stream_once(body: body) do |parsed, text_delta|
            last_parsed = parsed

            if (meta = parsed["usageMetadata"])
              last_usage = {
                prompt_tokens: Integer(meta.fetch("promptTokenCount", 0)),
                candidate_tokens: Integer(meta.fetch("candidatesTokenCount", 0)),
                thoughts_tokens: Integer(meta.fetch("thoughtsTokenCount", 0)),
                cached_content_tokens: Integer(meta.fetch("cachedContentTokenCount", 0)),
                total_tokens: Integer(meta.fetch("totalTokenCount", 0))
              }
            end

            next if text_delta.empty?

            emitted_any = true
            accumulated << text_delta
            yield text_delta, accumulated if block_given?
          end

          raise BackendError, "Gemini stream produced no text" if accumulated.empty?

          {
            text: accumulated,
            usage: last_usage || { prompt_tokens: 0, candidate_tokens: 0, thoughts_tokens: 0, cached_content_tokens: 0, total_tokens: 0 },
            raw: last_parsed,
            latency_s: monotonic_now - started
          }
        rescue BackendError => e
          raise e unless !emitted_any && retriable_error?(e) && attempts <= @max_retries

          backoff = backoff_seconds(attempts)
          notify_retry(on_retry: on_retry, mode: "stream", attempt: attempts, backoff_seconds: backoff, error: e)
          sleep(backoff)
          retry
        rescue StandardError => e
          raise BackendError, "Gemini stream request failed: #{e.class}: #{e.message}" unless !emitted_any && attempts <= @max_retries

          wrapped = BackendError.new("Gemini stream request failed: #{e.class}: #{e.message}")
          backoff = backoff_seconds(attempts)
          notify_retry(on_retry: on_retry, mode: "stream", attempt: attempts, backoff_seconds: backoff, error: wrapped)
          sleep(backoff)
          retry
        end
      end

      private

      def ensure_config!
        raise ConfigurationError, "model_name is required" if @model_name.to_s.strip.empty?
        raise ConfigurationError, "GEMINI_API_KEY is missing" if @api_key.to_s.strip.empty?
      end

      def uri
        URI("#{@base_url}/v1beta/models/#{@model_name}:generateContent?key=#{@api_key}")
      end

      def stream_uri
        URI("#{@base_url}/v1beta/models/#{@model_name}:streamGenerateContent?alt=sse&key=#{@api_key}")
      end

      def build_payload(messages:, generation_config:)
        normalized = Array(messages).map do |m|
          {
            role: m.fetch(:role, m["role"]).to_s,
            content: m.fetch(:content, m["content"]).to_s
          }
        end

        system_parts = normalized.select { |m| m[:role] == "system" }
        turn_messages = normalized.reject { |m| m[:role] == "system" }

        contents = turn_messages.map do |m|
          gemini_role = m[:role] == "assistant" ? "model" : "user"
          { role: gemini_role, parts: [{ text: m[:content] }] }
        end

        payload = { contents: contents }

        system_text = system_parts.map { |m| m[:content] }.join("\n\n").strip
        unless system_text.empty?
          payload[:systemInstruction] = { parts: [{ text: system_text }] }
        end

        config = normalize_generation_config(generation_config)
        payload[:generationConfig] = config unless config.empty?
        payload
      end

      def stream_once(body:)
        target_uri = stream_uri
        http = Net::HTTP.new(target_uri.host, target_uri.port)
        http.use_ssl = target_uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        request = Net::HTTP::Post.new(target_uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        http.start do
          http.request(request) do |response|
            status = response.code.to_i
            unless status < 300
              error_body = +""
              response.read_body { |chunk| error_body << chunk }
              raise build_stream_error(status, error_body)
            end

            buffer = +""
            response.read_body do |chunk|
              buffer << chunk
              while (line_end = buffer.index("\n"))
                line = buffer.slice!(0, line_end + 1).chomp
                next unless line.start_with?("data: ")

                json_str = line[6..]
                next if json_str == "[DONE]"

                parsed = JSON.parse(json_str) rescue next

                text_delta = Array(parsed.dig("candidates", 0, "content", "parts"))
                  .reject { |p| p["thought"] }
                  .map { |p| p["text"] }.compact.join

                yield parsed, text_delta
              end
            end
          end
        end
      end

      def build_stream_error(status, error_body)
        parsed = JSON.parse(error_body)
        message = parsed.dig("error", "message") || error_body
        error = BackendError.new("Gemini stream error (#{status}): #{message}")
        error.define_singleton_method(:status_code) { status.to_i }
        error
      rescue JSON::ParserError
        error = BackendError.new("Gemini stream error (#{status}): #{error_body}")
        error.define_singleton_method(:status_code) { status.to_i }
        error
      end

      def normalize_generation_config(generation_config)
        hash = {}
        Array(generation_config.to_h).each do |key, value|
          next if value.nil?

          gemini_key = case key.to_sym
                       when :response_mime_type then :responseMimeType
                       when :max_output_tokens then :maxOutputTokens
                       when :top_p then :topP
                       when :top_k then :topK
                       when :thinking_config then :thinkingConfig
                       else key
                       end
          hash[gemini_key] = value
        end
        hash
      end

      def notify_retry(on_retry:, mode:, attempt:, backoff_seconds:, error:)
        return unless on_retry

        on_retry.call(
          provider: "gemini",
          mode: mode,
          attempt: attempt,
          next_attempt: attempt + 1,
          max_retries: @max_retries,
          backoff_seconds: backoff_seconds,
          status_code: (error.respond_to?(:status_code) ? error.status_code.to_i : nil),
          error_message: error.message
        )
      rescue StandardError
        nil
      end

      def post_json(target_uri, payload)
        http = Net::HTTP.new(target_uri.host, target_uri.port)
        http.use_ssl = target_uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        request = Net::HTTP::Post.new(target_uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)

        http.request(request)
      end

      def parse_response(response)
        status = response.code.to_i
        parsed = JSON.parse(response.body)

        if status >= 200 && status < 300
          return parsed
        end

        message = parsed.dig("error", "message") || response.body
        error = BackendError.new("Gemini API error (#{status}): #{message}")
        error.define_singleton_method(:status_code) { status }
        raise error
      rescue JSON::ParserError
        raise BackendError, "Gemini API returned non-JSON response with status #{response.code}"
      end

      def extract_text(parsed)
        parts = parsed.dig("candidates", 0, "content", "parts")
        text = Array(parts).reject { |p| p["thought"] }.map { |part| part["text"] }.compact.join("\n").strip
        raise BackendError, "Gemini response did not include text content" if text.empty?

        text
      end

      def extract_usage(parsed)
        usage = parsed["usageMetadata"] || {}
        {
          prompt_tokens: Integer(usage.fetch("promptTokenCount", 0)),
          candidate_tokens: Integer(usage.fetch("candidatesTokenCount", 0)),
          thoughts_tokens: Integer(usage.fetch("thoughtsTokenCount", 0)),
          cached_content_tokens: Integer(usage.fetch("cachedContentTokenCount", 0)),
          total_tokens: Integer(usage.fetch("totalTokenCount", 0))
        }
      end

      def retriable_error?(error)
        return false unless error.respond_to?(:status_code)

        status = error.status_code.to_i
        status == 429 || status >= 500
      end

      def backoff_seconds(attempt)
        0.4 * (2**(attempt - 1))
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
