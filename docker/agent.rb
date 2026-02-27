require "json"
require "net/http"
require "open3"
require "socket"
require "stringio"
require "timeout"
require "uri"

CONTAINER_PORT = 9867

TYPE_INIT = "init"
TYPE_INIT_OK = "init_ok"
TYPE_EXECUTE = "execute"
TYPE_EXECUTE_RESULT = "execute_result"

class AgentHost
  GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"

  def initialize
    @context = nil
    @runtime = {}
  end

  def set_context(context)
    @context = context
  end

  def set_runtime(runtime)
    @runtime = runtime.to_h
  end

  def context
    @context
  end

  def llm_query(sub_prompt, model_name: nil)
    ensure_network_allowed!("llm_query")
    prompt = sub_prompt.to_s
    raise ArgumentError, "sub_prompt is required" if prompt.strip.empty?

    api_key = gemini_api_key
    model = model_name.to_s.strip
    model = @runtime["default_model_name"].to_s.strip if model.empty?
    model = "gemini-3.1-pro-preview" if model.empty?

    uri = URI.parse("#{GEMINI_API_BASE}/#{model}:generateContent?key=#{URI.encode_www_form_component(api_key)}")
    body = {
      contents: [
        {
          role: "user",
          parts: [{ text: prompt }]
        }
      ],
      generationConfig: {
        responseMimeType: "text/plain",
        temperature: 0.2
      }
    }

    response = with_http(uri) do |http|
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
      http.request(request)
    end

    status = response.code.to_i
    raise RuntimeError, "Gemini API HTTP #{status}: #{response.body}" unless status.between?(200, 299)

    parsed = JSON.parse(response.body)
    extract_text_from_gemini(parsed)
  end

  def fetch(url, headers: {}, max_redirects: 5)
    ensure_network_allowed!("fetch")
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
      return fetch(redirected_url, headers: headers, max_redirects: max_redirects - 1)
    end

    status = response.code.to_i
    body = response.body.to_s
    raise RuntimeError, "HTTP #{status}: #{truncate_text(body, 500)}" unless status.between?(200, 299)

    parse_http_body(body, content_type: response["content-type"])
  end

  def patch_file(_path, _old_text, _new_text)
    raise RuntimeError, "patch_file is disabled in strict Docker mode (no workspace mount)"
  end

  def grep(_pattern, path: ".")
    raise RuntimeError, "grep is disabled in strict Docker mode (no workspace mount), requested path=#{path}"
  end

  def sh(command, timeout: 5)
    cmd = command.to_s
    raise ArgumentError, "command is required" if cmd.strip.empty?

    timeout_seconds = timeout.to_f
    raise ArgumentError, "timeout must be > 0" unless timeout_seconds.positive?

    stdout_text = +""
    stderr_text = +""
    status = nil
    timed_out = false

    Open3.popen3("sh", "-lc", cmd, chdir: "/tmp", pgroup: true) do |stdin, stdout, stderr, wait_thr|
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

  def chunk_text(text, max_length: 2000)
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

  private

  def gemini_api_key
    secret_path = ENV["GEMINI_API_KEY_FILE"].to_s
    if !secret_path.empty? && File.file?(secret_path)
      key = File.read(secret_path).to_s.strip
      return key unless key.empty?
    end
    raise RuntimeError, "GEMINI_API_KEY_FILE secret is missing or empty in Docker container"
  end

  def ensure_network_allowed!(helper_name)
    return if @runtime[:allow_network] == true || @runtime["allow_network"] == true

    raise RuntimeError, "#{helper_name} is disabled because Docker network access is disabled"
  end

  def with_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.is_a?(URI::HTTPS)
    http.open_timeout = 10
    http.read_timeout = 60
    http.start { |session| yield session }
  end

  def extract_text_from_gemini(parsed)
    candidates = parsed.fetch("candidates", [])
    first = candidates.first || {}
    parts = first.dig("content", "parts") || []
    text = parts.map { |part| part["text"].to_s }.join
    return text unless text.strip.empty?

    raise RuntimeError, "Gemini response did not include text"
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

  def terminate_process_group(pid)
    return if pid.nil? || pid <= 0

    Process.kill("TERM", -pid)
    sleep 0.1
  rescue Errno::EPERM, Errno::ESRCH
    nil
  ensure
    Process.kill("KILL", -pid) rescue nil
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
end

def value_preview(value)
  text = value.inspect
  return text if text.length <= 500

  "#{text[0, 500]}...<truncated>"
end

def execute_with_host(host, code)
  stdout_buffer = StringIO.new
  stderr_buffer = StringIO.new
  prior_stdout = $stdout
  prior_stderr = $stderr
  value = nil

  begin
    $stdout = stdout_buffer
    $stderr = stderr_buffer
    wrapped_code = "context = self.context\n#{code}"
    value = host.__send__(:instance_eval, wrapped_code)
    {
      type: TYPE_EXECUTE_RESULT,
      ok: true,
      stdout: stdout_buffer.string,
      stderr: stderr_buffer.string,
      value_preview: value_preview(value)
    }
  rescue StandardError, ScriptError => e
    {
      type: TYPE_EXECUTE_RESULT,
      ok: false,
      stdout: stdout_buffer.string,
      stderr: stderr_buffer.string,
      error_class: e.class.name,
      error_message: e.message,
      backtrace_excerpt: Array(e.backtrace).first(5)
    }
  ensure
    $stdout = prior_stdout
    $stderr = prior_stderr
  end
end

server = TCPServer.new("0.0.0.0", CONTAINER_PORT)
socket = server.accept
agent = AgentHost.new
host = Object.new

host.define_singleton_method(:context) { agent.context }
host.define_singleton_method(:llm_query) { |sub_prompt, model_name: nil| agent.llm_query(sub_prompt, model_name: model_name) }
host.define_singleton_method(:fetch) { |url, headers: {}| agent.fetch(url, headers: headers) }
host.define_singleton_method(:patch_file) { |path, old_text, new_text| agent.patch_file(path, old_text, new_text) }
host.define_singleton_method(:grep) { |pattern, path: "."| agent.grep(pattern, path: path) }
host.define_singleton_method(:sh) { |command, timeout: 5| agent.sh(command, timeout: timeout) }
host.define_singleton_method(:chunk_text) { |text, max_length: 2000| agent.chunk_text(text, max_length: max_length) }

loop do
  line = socket.gets
  break if line.nil?

  message = JSON.parse(line, symbolize_names: true)
  case message[:type]
  when TYPE_INIT
    agent.set_context(message[:context])
    agent.set_runtime(message[:runtime] || {})
    socket.write("#{JSON.generate({ type: TYPE_INIT_OK })}\n")
  when TYPE_EXECUTE
    socket.write("#{JSON.generate(execute_with_host(host, message[:code].to_s))}\n")
  end
end
