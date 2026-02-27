require "open3"
require_relative "../../../rubyrlm/errors"
require_relative "protocol"

module RubyRLM
  module Repl
    class DockerRepl
      class ContainerManager
        attr_reader :container_id, :mapped_port

        def initialize(
          image: "rubyrlm/repl:latest",
          memory_limit: "256m",
          cpu_quota: 50_000,
          network_mode: "none",
          allow_network: false,
          gemini_api_key_secret: "gemini_api_key",
          gemini_api_key_secret_path: nil,
          gemini_api_key_proc: nil,
          keep_alive: false,
          reuse_container_id: nil
        )
          @image = image
          @memory_limit = memory_limit
          @cpu_quota = cpu_quota
          @network_mode = allow_network ? "bridge" : network_mode.to_s
          @allow_network = allow_network
          @gemini_api_key_secret = gemini_api_key_secret
          @gemini_api_key_secret_path = gemini_api_key_secret_path
          @gemini_api_key_proc = gemini_api_key_proc
          @keep_alive = keep_alive
          @reuse_container_id = reuse_container_id
          @generated_secret_path = nil
          @container_id = reuse_container_id || nil
          @mapped_port = nil
        end

        def start!
          verify_docker_available!
          if @reuse_container_id && running?
            # Eagerly attach to existing container
            @container_id = @reuse_container_id
            @mapped_port = discover_mapped_port!
            return
          end

          create_container!
          start_container!
          @mapped_port = discover_mapped_port!
        rescue StandardError => e
          stop!
          raise e
        end

        def stop!
          return unless @container_id
          return if @keep_alive || @reuse_container_id

          _stdout, _stderr, status = Open3.capture3("docker", "stop", "-t", "2", @container_id)
          Open3.capture3("docker", "kill", @container_id) unless status.success?
        ensure
          cleanup_generated_secret! unless @keep_alive || @reuse_container_id
          @container_id = nil unless @keep_alive || @reuse_container_id
          @mapped_port = nil unless @keep_alive || @reuse_container_id
        end

        def running?
          return false unless @container_id

          stdout, _stderr, status = Open3.capture3("docker", "inspect", "-f", "{{.State.Running}}", @container_id)
          status.success? && stdout.to_s.strip == "true"
        end

        private

        def verify_docker_available!
          _stdout, stderr, status = Open3.capture3("docker", "info")
          return if status.success?

          raise RubyRLM::ReplError, "Docker is unavailable: #{stderr.to_s.strip}"
        end

        def create_container!
          secret_path = ensure_secret_file!
          args = [
            "docker", "create",
            "--memory", @memory_limit.to_s,
            "--cpu-quota", @cpu_quota.to_s,
            "--network", @network_mode.to_s,
            "--publish", "0:#{Protocol::CONTAINER_PORT}",
            "--mount", "type=bind,source=#{secret_path},target=/run/secrets/#{@gemini_api_key_secret},readonly",
            "--env", "GEMINI_API_KEY_FILE=/run/secrets/#{@gemini_api_key_secret}",
            "--rm",
          ]
          # Use public DNS to avoid Docker Desktop DNS resolution issues on macOS
          args.push("--dns", "8.8.8.8") if @allow_network
          args.push(@image.to_s)

          stdout, stderr, status = Open3.capture3(*args)
          raise RubyRLM::ReplError, "docker create failed: #{stderr.to_s.strip}" unless status.success?

          @container_id = stdout.to_s.strip
          raise RubyRLM::ReplError, "docker create returned empty container id" if @container_id.empty?
        end

        def start_container!
          _stdout, stderr, status = Open3.capture3("docker", "start", @container_id)
          return if status.success?

          raise RubyRLM::ReplError, "docker start failed: #{stderr.to_s.strip}"
        end

        def discover_mapped_port!
          stdout, stderr, status = Open3.capture3("docker", "port", @container_id, Protocol::CONTAINER_PORT.to_s)
          raise RubyRLM::ReplError, "docker port failed: #{stderr.to_s.strip}" unless status.success?

          # Typical output:
          # 0.0.0.0:49153
          # [::]:49153
          line = stdout.to_s.lines.map(&:strip).find { |entry| entry.include?(":") && !entry.empty? }
          raise RubyRLM::ReplError, "docker port returned no mapped port" unless line

          port = line.split(":").last.to_i
          raise RubyRLM::ReplError, "docker port returned invalid mapping: #{line}" unless port.positive?

          port
        end

        def ensure_secret_file!
          explicit_path = @gemini_api_key_secret_path.to_s.strip
          if !explicit_path.empty?
            unless File.file?(explicit_path)
              raise RubyRLM::ReplError, "gemini_api_key_secret_path does not exist: #{explicit_path}"
            end
            return explicit_path
          end

          key = @gemini_api_key_proc&.call.to_s
          tmp_path = "/tmp/rubyrlm-gemini-key-#{Process.pid}-#{object_id}.txt"
          File.write(tmp_path, "#{key}\n", mode: "w", perm: 0o600)
          @generated_secret_path = tmp_path
          tmp_path
        end

        def cleanup_generated_secret!
          return unless @generated_secret_path
          return unless File.exist?(@generated_secret_path)

          File.delete(@generated_secret_path)
        rescue StandardError
          nil
        ensure
          @generated_secret_path = nil
        end
      end
    end
  end
end
