require "json"
require "net/http"
require "open3"
require "pathname"
require "uri"

module RubyRLM
  module Repl
    class DockerRepl
      class HostRpcServer
        def initialize(context:, llm_query_proc:, workspace_root:)
          @context = context
          @llm_query_proc = llm_query_proc
          @workspace_root = Pathname.new(workspace_root).expand_path
        end

        def dispatch(method_name, params = {})
          case method_name.to_s
          when "llm_query"
            @llm_query_proc.call(params.fetch("sub_prompt", params[:sub_prompt]), model_name: params["model_name"] || params[:model_name])
          when "patch_file"
            patch_file_safely(params.fetch("path", params[:path]), params.fetch("old_text", params[:old_text]), params.fetch("new_text", params[:new_text]))
          when "grep"
            grep_codebase(params.fetch("pattern", params[:pattern]), path: params["path"] || params[:path] || ".")
          when "fetch"
            fetch_url(params.fetch("url", params[:url]), headers: params["headers"] || params[:headers] || {})
          when "context"
            @context
          else
            raise ArgumentError, "Unknown host RPC helper: #{method_name}"
          end
        end

        private

        def fetch_url(url, headers: {}, max_redirects: 5)
          raise ArgumentError, "URL is required" if url.to_s.strip.empty?
          raise RuntimeError, "Too many redirects" if max_redirects.negative?

          uri = URI.parse(url.to_s)
          unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
            raise ArgumentError, "Unsupported URL scheme: #{uri.scheme.inspect}"
          end

          request = Net::HTTP::Get.new(uri)
          headers.to_h.each { |key, value| request[key.to_s] = value.to_s }

          response = with_http(uri) { |http| http.request(request) }
          if response.is_a?(Net::HTTPRedirection)
            location = response["location"].to_s
            raise RuntimeError, "Redirect response missing Location header" if location.empty?

            redirected_url = URI.join(uri.to_s, location).to_s
            return fetch_url(redirected_url, headers: headers, max_redirects: max_redirects - 1)
          end

          status = response.code.to_i
          body = response.body.to_s
          raise RuntimeError, "HTTP #{status}: #{truncate_text(body, 500)}" unless status.between?(200, 299)

          parse_http_body(body, content_type: response["content-type"])
        end

        def patch_file_safely(path, old_text, new_text)
          target = resolve_workspace_path(path)
          raise ArgumentError, "File not found: #{path}" unless target.file?

          needle = old_text.to_s
          raise ArgumentError, "old_text cannot be empty" if needle.empty?

          content = File.read(target)
          occurrences = content.split(needle, -1).length - 1
          unless occurrences == 1
            raise RuntimeError, "old_text must appear exactly once (found #{occurrences})"
          end

          updated = content.sub(needle, new_text.to_s)
          File.write(target, updated)

          { path: to_relative_path(target), replaced: 1, bytes_written: updated.bytesize }
        end

        def grep_codebase(pattern, path: ".")
          query = pattern.to_s
          raise ArgumentError, "pattern is required" if query.strip.empty?

          search_root = resolve_workspace_path(path)
          raise ArgumentError, "path not found: #{path}" unless search_root.exist?

          search_path = to_relative_path(search_root)
          search_path = "." if search_path.empty?

          stdout_text, stderr_text, status = Open3.capture3(
            "rg",
            "--line-number",
            "--with-filename",
            "--no-heading",
            "--color",
            "never",
            query,
            search_path,
            chdir: @workspace_root.to_s
          )

          return [] if status.exitstatus == 1
          if status.exitstatus != 0
            message = stderr_text.to_s.strip
            message = stdout_text.to_s.strip if message.empty?
            raise RuntimeError, "grep failed: #{message}"
          end

          stdout_text.lines.map do |line|
            file, line_no, text = line.chomp.split(":", 3)
            { path: file, line: line_no.to_i, text: text.to_s }
          end
        end

        def with_http(uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.is_a?(URI::HTTPS)
          http.open_timeout = 10
          http.read_timeout = 30
          http.start { |session| yield session }
        end

        def parse_http_body(body, content_type:)
          json_like = content_type.to_s.include?("application/json") || body.lstrip.start_with?("{", "[")
          return body unless json_like

          JSON.parse(body)
        rescue JSON::ParserError
          body
        end

        def truncate_text(text, max)
          return text if text.length <= max

          "#{text[0, max]}...<truncated>"
        end

        def resolve_workspace_path(path)
          value = path.to_s
          raise ArgumentError, "path is required" if value.strip.empty?

          candidate = Pathname.new(value)
          absolute = candidate.absolute? ? candidate.expand_path : @workspace_root.join(candidate).expand_path
          root = @workspace_root.to_s
          absolute_str = absolute.to_s
          if absolute_str == root || absolute_str.start_with?("#{root}#{File::SEPARATOR}")
            absolute
          else
            raise ArgumentError, "Path escapes workspace root: #{path}"
          end
        end

        def to_relative_path(pathname)
          pathname.relative_path_from(@workspace_root).to_s
        rescue StandardError
          pathname.to_s
        end
      end
    end
  end
end
