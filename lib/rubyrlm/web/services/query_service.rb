require "securerandom"
require_relative "event_broadcaster"

module RubyRLM
  module Web
    module Services
      class QueryService
        def initialize(log_dir:, cleanup_ttl_seconds: 60, cleanup_interval_seconds: 5)
          @log_dir = log_dir
          @active_runs = {} # run_id => { thread:, broadcaster:, terminal:, terminal_at: }
          @mutex = Mutex.new
          @cleanup_ttl_seconds = cleanup_ttl_seconds.to_f
          @cleanup_interval_seconds = cleanup_interval_seconds.to_f
          # Best-effort cleanup for terminal runs with no subscribers.
          @reaper_thread = Thread.new { orphan_reaper_loop }
          @reaper_thread.report_on_exception = false
        end

        def start_run(
          prompt:,
          model_name: "gemini-3.1-pro-preview",
          max_iterations: 30,
          iteration_timeout: 60,
          max_depth: 1,
          temperature: 0.5,
          thinking_level: nil,
          session_id: nil,
          fork: false,
          environment: "docker",
          environment_options: { allow_network: true },
          **_unused
        )
          broadcaster = EventBroadcaster.new
          jsonl_logger = RubyRLM::Logger::JsonlLogger.new(log_dir: @log_dir)
          logger = StreamingLogger.new(jsonl_logger: jsonl_logger, broadcaster: broadcaster)

          run_id = SecureRandom.uuid
          target_session_id = resolve_target_session_id(request_id: run_id, session_id: session_id, fork: fork)
          continuation_mode =
            if fork
              "fork"
            elsif session_id
              "append"
            else
              "new"
            end
          source_session_id = session_id&.to_s&.strip
          source_session_id = nil if source_session_id&.empty?
          generation_config = {
            response_mime_type: "application/json",
            temperature: temperature
          }
          normalized_thinking_level = normalize_thinking_level(thinking_level)
          if normalized_thinking_level
            generation_config[:thinking_config] = { thinkingLevel: normalized_thinking_level }
          end

          thread = Thread.new do
            begin
              client = RubyRLM::Client.new(
                backend: "gemini",
                model_name: model_name,
                api_key: ENV["GEMINI_API_KEY"],
                max_iterations: max_iterations,
                iteration_timeout: iteration_timeout,
                max_depth: max_depth,
                logger: logger,
                streaming: true,
                environment: environment,
                environment_options: environment_options,
                run_id: target_session_id,
                run_metadata: {
                  continuation_mode: continuation_mode,
                  source_session_id: source_session_id
                },
                generation_config: generation_config
              )
              result = client.completion(prompt: prompt)
              broadcaster.broadcast(
                {
                  type: "run_complete",
                  response: result.response,
                  execution_time: result.execution_time,
                  session_id: target_session_id
                }
              )
            rescue StandardError, ScriptError => e
              broadcaster.broadcast({ type: "run_error", error: e.message, session_id: target_session_id })
            ensure
              mark_run_terminal(run_id)
            end
          end
          thread.report_on_exception = false

          @mutex.synchronize do
            @active_runs[run_id] = {
              thread: thread,
              broadcaster: broadcaster,
              terminal: false,
              terminal_at: nil
            }
          end
          run_id
        end

        def stream_events(run_id)
          run = @mutex.synchronize { @active_runs[run_id] }
          return nil unless run
          # Each subscriber gets an independent queue fed by the broadcaster.
          subscriber_id, queue = run[:broadcaster].subscribe

          Enumerator.new do |yielder|
            loop do
              event =
                begin
                  queue.pop(true)
                rescue ThreadError
                  nil
                end

              if event
                yielder.yield(event)
                break if event[:type] == "run_complete" || event[:type] == "run_error"
                next
              end

              # Safety net: if the worker exited without a terminal event,
              # emit a synthetic run_error so SSE clients do not hang forever.
              worker = run[:thread]
              if worker && !worker.alive?
                worker_error =
                  begin
                    worker.value
                    "Run terminated unexpectedly before completion"
                  rescue StandardError, ScriptError => e
                    e.message.to_s.empty? ? e.class.name : e.message
                  end

                yielder.yield(type: "run_error", error: worker_error)
                break
              end

              sleep 0.05
            end
          ensure
            @mutex.synchronize do
              current = @active_runs[run_id]
              next unless current

              current[:broadcaster].unsubscribe(subscriber_id)
              @active_runs.delete(run_id) if current[:terminal] && current[:broadcaster].subscriber_count.zero?
            end
          end
        end

        def cancel_run(run_id)
          run = @mutex.synchronize { @active_runs[run_id] }
          return false unless run
          run[:broadcaster]&.broadcast({ type: "run_error", error: "Run cancelled by user" })
          run[:thread]&.kill
          @mutex.synchronize { @active_runs.delete(run_id) }
          true
        end

        private

        def mark_run_terminal(run_id)
          @mutex.synchronize do
            run = @active_runs[run_id]
            next unless run

            run[:terminal] = true
            run[:terminal_at] = Time.now
          end
        end

        def orphan_reaper_loop
          loop do
            sleep @cleanup_interval_seconds
            now = Time.now
            @mutex.synchronize do
              @active_runs.delete_if do |_run_id, run|
                next false unless run[:terminal]
                next false unless run[:broadcaster].subscriber_count.zero?

                terminal_at = run[:terminal_at]
                terminal_at && (now - terminal_at) >= @cleanup_ttl_seconds
              end
            end
          end
        rescue StandardError
          nil
        end

        def resolve_target_session_id(request_id:, session_id:, fork:)
          clean_session_id = normalize_session_id(session_id)
          return request_id if fork || clean_session_id.nil?

          clean_session_id
        end

        def normalize_session_id(session_id)
          value = session_id.to_s.strip
          return nil if value.empty?
          raise ArgumentError, "Invalid session_id format" unless value.match?(/\A[a-zA-Z0-9_-]+\z/)

          value
        end

        def normalize_thinking_level(thinking_level)
          value = thinking_level.to_s.strip.downcase
          return nil if value.empty?

          return value if %w[low medium high].include?(value)

          nil
        end
      end
    end
  end
end
