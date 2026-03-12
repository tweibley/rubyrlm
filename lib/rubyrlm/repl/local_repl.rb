require_relative "code_validator"
require_relative "execution_result"
require "stringio"
require "timeout"
require "json"
require "net/http"
require "open3"
require "pathname"
require "uri"

module RubyRLM
  module Repl
    class LocalRepl
      DEFAULT_TIMEOUT_SECONDS = 60
      class IndifferentHash < Hash
        def initialize(source = {})
          super()
          merge!(source)
        end

        def [](key)
          super(normalize_key(key))
        end

        def []=(key, value)
          super(normalize_key(key), convert_value(value))
        end

        def fetch(key, *args, &block)
          super(normalize_key(key), *args, &block)
        end

        def key?(key)
          super(normalize_key(key))
        end
        alias has_key? key?

        def dig(key, *rest)
          value = self[key]
          return value if rest.empty? || value.nil?

          if value.respond_to?(:dig)
            value.dig(*rest)
          else
            rest.reduce(value) { |acc, next_key| acc.respond_to?(:[]) ? acc[next_key] : nil }
          end
        end

        def merge!(other_hash)
          other_hash.each { |key, value| self[key] = value }
          self
        end

        private

        def normalize_key(key)
          return key.to_sym if key.is_a?(String) || key.is_a?(Symbol)

          key
        end

        def convert_value(value)
          case value
          when Hash
            self.class.new(value)
          when Array
            value.map { |item| convert_value(item) }
          else
            value
          end
        end
      end

      attr_reader :modifications

      def initialize(context:, llm_query_proc:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
        @context = deep_indifferentize(context)
        @llm_query_proc = llm_query_proc
        @timeout_seconds = timeout_seconds
        @workspace_root = Pathname.new(Dir.pwd).expand_path
        @modifications = []
        @host = Object.new
        @host.instance_variable_set(:@context, @context)
        install_helpers
      end

      def execute(code)
        # AST validation: catch syntax errors and dangerous calls before eval
        begin
          warnings = CodeValidator.validate!(code)
        rescue CodeValidationError => e
          return ExecutionResult.new(
            ok: false,
            stdout: "",
            stderr: "",
            error_class: "CodeValidationError",
            error_message: e.message,
            backtrace_excerpt: []
          )
        end

        stdout_buffer = StringIO.new
        stderr_buffer = StringIO.new
        prior_stdout = $stdout
        prior_stderr = $stderr
        value = nil

        begin
          $stdout = stdout_buffer
          $stderr = stderr_buffer
          Timeout.timeout(@timeout_seconds) do
            wrapped_code = "context = self.context\n#{code}"
            value = @host.instance_eval(wrapped_code)
          end
          ExecutionResult.new(
            ok: true,
            stdout: stdout_buffer.string,
            stderr: stderr_buffer.string,
            value_preview: value_preview(value),
            warnings: warnings
          )
        rescue ::Timeout::Error
          ExecutionResult.new(
            ok: false,
            stdout: stdout_buffer.string,
            stderr: stderr_buffer.string,
            error_class: "Timeout::Error",
            error_message: "Execution exceeded #{@timeout_seconds} seconds",
            backtrace_excerpt: [],
            warnings: warnings
          )
        rescue StandardError, ScriptError => e
          ExecutionResult.new(
            ok: false,
            stdout: stdout_buffer.string,
            stderr: stderr_buffer.string,
            error_class: e.class.name,
            error_message: e.message,
            backtrace_excerpt: Array(e.backtrace).first(5),
            warnings: warnings
          )
        ensure
          $stdout = prior_stdout
          $stderr = prior_stderr
        end
      end

      private

      def install_helpers
        query_proc = @llm_query_proc
        fetch_proc = method(:fetch_url)
        sh_proc = method(:run_shell)
        patch_proc = method(:patch_file_safely)
        grep_proc = method(:grep_codebase)
        chunk_proc = method(:chunk_text_semantically)

        @host.define_singleton_method(:context) do
          @context
        end
        @host.define_singleton_method(:llm_query) do |sub_prompt, model_name: nil|
          query_proc.call(sub_prompt, model_name: model_name)
        end
        @host.define_singleton_method(:fetch) do |url, headers: {}|
          fetch_proc.call(url, headers: headers)
        end
        @host.define_singleton_method(:sh) do |command, timeout: 5|
          sh_proc.call(command, timeout: timeout)
        end
        @host.define_singleton_method(:patch_file) do |path, old_text, new_text|
          patch_proc.call(path, old_text, new_text)
        end
        @host.define_singleton_method(:grep) do |pattern, path: "."|
          grep_proc.call(pattern, path: path)
        end
        @host.define_singleton_method(:chunk_text) do |text, max_length: 2000|
          chunk_proc.call(text, max_length: max_length)
        end
        @host.define_singleton_method(:parallel_queries) do |*queries, max_concurrency: 5|
          queries = queries.flatten
          queries.each_slice(max_concurrency).flat_map do |batch|
            threads = batch.map do |q|
              Thread.new do
                if q.is_a?(Hash)
                  query_proc.call(q[:prompt] || q["prompt"], model_name: q[:model_name] || q["model_name"])
                else
                  query_proc.call(q.to_s)
                end
              end
            end
            threads.map(&:value)
          end
        end
      end

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

      def run_shell(command, timeout: 5)
        cmd = command.to_s
        raise ArgumentError, "command is required" if cmd.strip.empty?

        timeout_seconds = timeout.to_f
        raise ArgumentError, "timeout must be > 0" unless timeout_seconds.positive?

        stdout_text = +""
        stderr_text = +""
        status = nil
        timed_out = false

        Open3.popen3("sh", "-lc", cmd, chdir: @workspace_root.to_s, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          stdout_reader = Thread.new { stdout.read.to_s }
          stderr_reader = Thread.new { stderr.read.to_s }

          begin
            Timeout.timeout(timeout_seconds) { status = wait_thr.value }
          rescue Timeout::Error
            timed_out = true
            terminate_process_group(wait_thr.pid)
            status = wait_thr.value rescue nil
          ensure
            stdout_text = stdout_reader.value
            stderr_text = stderr_reader.value
          end
        end

        {
          stdout: stdout_text,
          stderr: stderr_text,
          exit_code: status&.exitstatus,
          ok: !timed_out && status&.success? == true,
          timed_out: timed_out
        }
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

        # Track modification for audit trail and undo
        @modifications << {
          path: target.to_s,
          relative_path: to_relative_path(target),
          old_text: needle,
          new_text: new_text.to_s,
          timestamp: Time.now.iso8601
        }

        updated = content.sub(needle, new_text.to_s)
        File.write(target, updated)

        { path: to_relative_path(target), replaced: 1, bytes_written: updated.bytesize }
      end

      def undo_last_patch
        mod = @modifications.pop
        return nil unless mod

        content = File.read(mod[:path])
        restored = content.sub(mod[:new_text], mod[:old_text])
        File.write(mod[:path], restored)
        { path: mod[:relative_path], restored: true }
      end

      def undo_all_patches
        results = []
        results << undo_last_patch until @modifications.empty?
        results.compact
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

      def chunk_text_semantically(text, max_length: 2000)
        max = Integer(max_length)
        raise ArgumentError, "max_length must be > 0" unless max.positive?

        normalized = text.to_s.gsub(/\r\n?/, "\n").strip
        return [] if normalized.empty?

        segments = normalized.split(/\n{2,}/).map(&:strip).reject(&:empty?).flat_map do |paragraph|
          split_semantic_unit(paragraph, max)
        end

        chunks = []
        current = +""
        segments.each do |segment|
          if current.empty?
            current = segment
          elsif (current.length + 2 + segment.length) <= max
            current = "#{current}\n\n#{segment}"
          else
            chunks << current
            current = segment
          end
        end
        chunks << current unless current.empty?
        chunks
      end

      def value_preview(value)
        text = value.inspect
        return text if text.length <= 500

        "#{text[0, 500]}...<truncated>"
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

        parsed = JSON.parse(body)
        deep_indifferentize(parsed)
      rescue JSON::ParserError
        body
      end

      def truncate_text(text, max)
        return text if text.length <= max

        "#{text[0, max]}...<truncated>"
      end

      def terminate_process_group(pid)
        return if pid.nil? || pid <= 0

        target = Gem.win_platform? ? pid : -pid
        Process.kill("TERM", target)
        sleep 0.1
      rescue Errno::EPERM, Errno::ESRCH
        nil
      ensure
        Process.kill("KILL", target) rescue nil
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

      def split_semantic_unit(text, max_length)
        return [text] if text.length <= max_length

        sentences = text.scan(/[^.!?\n]+(?:[.!?]+|$)/).map(&:strip).reject(&:empty?)
        sentences = [text] if sentences.empty?

        parts = []
        current = +""
        sentences.each do |sentence|
          if sentence.length > max_length
            parts << current unless current.empty?
            current = +""
            parts.concat(hard_wrap(sentence, max_length))
            next
          end

          if current.empty?
            current = sentence
          elsif (current.length + 1 + sentence.length) <= max_length
            current = "#{current} #{sentence}"
          else
            parts << current
            current = sentence
          end
        end
        parts << current unless current.empty?
        parts
      end

      def hard_wrap(text, max_length)
        chunks = []
        remaining = text.dup
        until remaining.empty?
          break_point = remaining.rindex(" ", max_length) || max_length
          chunk = remaining[0, break_point].strip
          if chunk.empty?
            chunk = remaining[0, max_length]
            remaining = remaining[max_length..] || +""
          else
            remaining = remaining[break_point..] || +""
          end
          chunks << chunk
          remaining = remaining.lstrip
        end
        chunks
      end

      def deep_indifferentize(value)
        case value
        when Hash
          IndifferentHash.new(value)
        when Array
          value.map { |item| deep_indifferentize(item) }
        else
          value
        end
      end
    end
  end
end
