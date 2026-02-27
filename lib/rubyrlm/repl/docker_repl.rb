require "socket"
require "timeout"
require "json"

require_relative "execution_result"
require_relative "docker_repl/protocol"
require_relative "docker_repl/container_manager"

module RubyRLM
  module Repl
    class DockerRepl
      DEFAULT_TIMEOUT_SECONDS = 60

      def initialize(context:, llm_query_proc:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, **options)
        @timeout_seconds = timeout_seconds
        @connect_timeout = Integer(options.fetch(:connect_timeout, 10))
        container_options = options.reject { |key, _value| key.to_sym == :model_name }
        @container_manager = ContainerManager.new(
          **container_options,
          gemini_api_key_proc: method(:gemini_api_key)
        )
        @context = context
        @default_model_name = options[:model_name]
        @allow_network = options[:allow_network] == true
        @socket = nil
        @started = false
      end

      def container_id
        @container_manager.container_id
      end

      def execute(code)
        deadline = monotonic_now + @timeout_seconds.to_f
        ensure_started!(deadline: deadline)
        send_message(type: Protocol::TYPE_EXECUTE, code: code.to_s, deadline: deadline)

        loop do
          message = read_message(deadline: deadline)
          raise RubyRLM::ReplError, "Container closed connection unexpectedly" if message.nil?

          case message[:type]
          when Protocol::TYPE_EXECUTE_RESULT
            return execution_result_from_payload(message)
          else
            raise RubyRLM::ReplError, "Unknown message type from container: #{message[:type].inspect}"
          end
        end
      rescue ::Timeout::Error
        reset_transport!
        ExecutionResult.new(
          ok: false,
          stdout: "",
          stderr: "",
          error_class: "Timeout::Error",
          error_message: "Execution exceeded #{@timeout_seconds} seconds",
          backtrace_excerpt: []
        )
      rescue RubyRLM::ReplError, IOError, SystemCallError, JSON::ParserError => e
        reset_transport!
        ExecutionResult.new(
          ok: false,
          stdout: "",
          stderr: "",
          error_class: e.class.name,
          error_message: e.message,
          backtrace_excerpt: Array(e.backtrace).first(5)
        )
      end

      def shutdown
        reset_transport!
      end

      def start!(deadline: nil)
        deadline ||= monotonic_now + @timeout_seconds.to_f
        ensure_started!(deadline: deadline)
        self
      end

      private

      def ensure_started!(deadline:)
        return if @started && socket_open?

        @container_manager.start! unless @container_manager.running?
        connect_and_init_socket!(deadline: deadline)
      end

      def connect_and_init_socket!(deadline:)
        last_error = nil
        until monotonic_now >= deadline
          begin
            connect_socket!(deadline: deadline)
            send_message(
              type: Protocol::TYPE_INIT,
              context: @context,
              runtime: {
                default_model_name: @default_model_name,
                allow_network: @allow_network
              },
              deadline: deadline
            )
            init_reply = read_message(deadline: deadline)
            unless init_reply && init_reply[:type] == Protocol::TYPE_INIT_OK
              raise RubyRLM::ReplError, "Unexpected init handshake response: #{init_reply.inspect}"
            end
            @started = true
            return
          rescue IOError, SystemCallError, JSON::ParserError, RubyRLM::ReplError => e
            last_error = e
            close_socket
            sleep 0.1
          end
        end

        raise(last_error || RubyRLM::ReplError.new("Container agent did not become ready"))
      end

      def connect_socket!(deadline:)
        with_deadline(deadline) do |remaining|
          timeout_budget = [remaining, @connect_timeout.to_f].min
          @socket = Timeout.timeout(timeout_budget) { TCPSocket.new("127.0.0.1", @container_manager.mapped_port) }
        end
      end

      def close_socket
        @socket&.close
      rescue IOError, SystemCallError
        nil
      ensure
        @socket = nil
      end

      def send_message(deadline:, **payload)
        with_deadline(deadline) do
          @socket.write(Protocol.encode(payload))
        end
      end

      def read_message(deadline:)
        with_deadline(deadline) do
          line = @socket.gets
          return nil if line.nil?

          Protocol.decode(line)
        end
      end

      def execution_result_from_payload(payload)
        ExecutionResult.new(
          ok: payload[:ok] == true,
          stdout: payload[:stdout].to_s,
          stderr: payload[:stderr].to_s,
          value_preview: payload[:value_preview],
          error_class: payload[:error_class],
          error_message: payload[:error_message],
          backtrace_excerpt: payload[:backtrace_excerpt] || []
        )
      end

      def with_deadline(deadline)
        remaining = deadline - monotonic_now
        raise ::Timeout::Error, "Execution deadline exceeded" unless remaining.positive?

        Timeout.timeout(remaining) { yield(remaining) }
      end

      def socket_open?
        !@socket.nil? && !@socket.closed?
      rescue IOError
        false
      end

      def reset_transport!
        close_socket
        @started = false
        @container_manager&.stop!
      end

      def gemini_api_key
        ENV["GEMINI_API_KEY"]
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
