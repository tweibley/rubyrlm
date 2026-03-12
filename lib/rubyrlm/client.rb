require "json"
require "securerandom"

module RubyRLM
  class Client
    DEFAULT_MAX_DEPTH = 1
    DEFAULT_MAX_ITERATIONS = 30
    DEFAULT_ITERATION_TIMEOUT = 60
    DEFAULT_MAX_MESSAGES = 50
    DEFAULT_COMPACTION = true
    DEFAULT_COMPACTION_THRESHOLD = 0.7
    DEFAULT_COMPACTION_MODEL = Compaction::MessageCompactor::DEFAULT_COMPACTION_MODEL

    attr_reader :backend, :model_name, :max_depth, :max_iterations, :max_messages, :depth

    def initialize(
      backend: "gemini",
      model_name:,
      api_key: ENV["GEMINI_API_KEY"],
      max_depth: DEFAULT_MAX_DEPTH,
      max_iterations: DEFAULT_MAX_ITERATIONS,
      depth: 0,
      logger: nil,
      verbose: false,
      streaming: false,
      generation_config: {},
      backend_options: {},
      environment: "local",
      environment_options: {},
      iteration_timeout: DEFAULT_ITERATION_TIMEOUT,
      max_messages: DEFAULT_MAX_MESSAGES,
      compaction: DEFAULT_COMPACTION,
      compaction_threshold: DEFAULT_COMPACTION_THRESHOLD,
      compaction_model: DEFAULT_COMPACTION_MODEL,
      subcall_model: nil,
      budget: nil,
      budget_tracker: nil,
      parent_run_id: nil,
      run_id: nil,
      run_metadata: {},
      backend_client: nil
    )
      @backend = backend.to_s
      @model_name = model_name
      @api_key = api_key
      @max_depth = max_depth
      @max_iterations = max_iterations
      @depth = depth
      @logger = logger
      @verbose = verbose
      @streaming = streaming
      @environment = environment
      @environment_options = environment_options
      @iteration_timeout = iteration_timeout
      @max_messages = max_messages
      @generation_config = {
        response_mime_type: "application/json",
        temperature: 0.5
      }.merge(generation_config || {})
      @backend_options = backend_options || {}
      @parent_run_id = parent_run_id
      @run_id = run_id
      @run_metadata = run_metadata || {}
      @action_parser = Protocol::ActionParser.new
      @backend_client = backend_client || build_backend_client(model_name: @model_name)
      @sub_call_cache = SubCallCache.new
      @compaction_model = compaction_model.to_s
      @compactor = Compaction::MessageCompactor.new(
        enabled: compaction.nil? ? true : compaction,
        threshold: compaction_threshold,
        max_messages: @max_messages,
        compaction_model: @compaction_model,
        backend_builder: method(:build_backend_client)
      )
      @subcall_model = subcall_model
      @budget_tracker = budget_tracker || build_budget_tracker(budget)
      @current_run_id = nil

      validate_config!
    end

    def completion(prompt:, root_prompt: nil)
      started = monotonic_now
      usage_summary = UsageSummary.new
      run_id = @run_id || SecureRandom.uuid
      @current_run_id = run_id
      messages = initial_messages(prompt: prompt, root_prompt: root_prompt)
      repl = build_repl(prompt)
      repl.start! if repl.respond_to?(:start!)

      metadata = {
        run_id: run_id,
        parent_run_id: @parent_run_id,
        depth: @depth,
        max_depth: @max_depth,
        max_iterations: @max_iterations,
        iterations: [],
        compaction_events: []
      }
      metadata[:container_id] = repl.container_id if repl.respond_to?(:container_id) && repl.container_id

      run_start_event = {
        type: "run_start",
        run_id: run_id,
        parent_run_id: @parent_run_id,
        depth: @depth,
        model: @model_name,
        prompt: prompt.is_a?(String) ? prompt : "Complex context"
      }.merge(@run_metadata)
      run_start_event[:container_id] = repl.container_id if repl.respond_to?(:container_id) && repl.container_id
      log_event(run_start_event)
      verbose_log("run_start", "depth=#{@depth} model=#{@model_name} run_id=#{run_id}")

      if @run_metadata && @run_metadata[:continuation_mode] == "append"
        marker = CONTINUATION_NEW_REQUEST_MARKER
        if prompt.is_a?(String) && prompt.include?(marker)
          marker_idx = prompt.rindex(marker)
          new_request = prompt[(marker_idx + marker.length)..].strip
          user_prompt_data = {
            iteration: 0,
            action: "user_prompt",
            prompt: new_request,
            latency_s: 0.0
          }
          metadata[:iterations] << user_prompt_data
          log_event(type: "iteration", run_id: run_id, data: user_prompt_data)
        end
      end

      final_answer = nil

      1.upto(@max_iterations) do |iteration|
        turn = request_action(messages: messages, usage_summary: usage_summary)
        action = turn.fetch(:action)
        raw_text = turn.fetch(:raw_text)
        verbose_log(
          "iteration",
          "depth=#{@depth} iteration=#{iteration} action=#{action[:action]} latency=#{format('%.2f', turn[:latency_s])}s#{turn[:repaired] ? ' repaired=true' : ''}"
        )

        case action[:action]
        when "exec"
          verbose_block("exec_code", action.fetch(:code))
          execution = repl.execute(action.fetch(:code))
          verbose_execution(execution)
          feedback = execution_feedback(execution)
          messages << { role: "assistant", content: raw_text }
          messages << { role: "user", content: feedback }
          maybe_compact_and_truncate!(messages, metadata: metadata, usage_summary: usage_summary)
          iteration_data = {
            iteration: iteration,
            action: "exec",
            code: action.fetch(:code),
            execution: execution.to_h,
            latency_s: turn[:latency_s],
            repaired: turn[:repaired] || false,
            usage: turn[:usage]
          }
          metadata[:iterations] << iteration_data
          log_event(type: "iteration", run_id: run_id, data: iteration_data)
        when "final"
          final_answer = action.fetch(:answer)
          verbose_block("final_answer", final_answer)
          messages << { role: "assistant", content: raw_text }
          truncate_messages!(messages)
          iteration_data = {
            iteration: iteration,
            action: "final",
            answer: final_answer,
            latency_s: turn[:latency_s],
            repaired: turn[:repaired] || false,
            usage: turn[:usage]
          }
          metadata[:iterations] << iteration_data
          log_event(type: "iteration", run_id: run_id, data: iteration_data)
          break
        end
      end

      if final_answer.nil?
        forced = force_final(messages: messages, usage_summary: usage_summary)
        final_answer = forced.fetch(:answer)
        metadata[:forced_final] = true
        metadata[:iterations] << forced.fetch(:iteration_data)
        log_event(type: "iteration", run_id: run_id, data: forced.fetch(:iteration_data))
        verbose_block("forced_final_answer", final_answer)
      end

      execution_time = monotonic_now - started

      # Enrich metadata with patch tracking and cache stats
      if repl.respond_to?(:modifications) && !repl.modifications.empty?
        metadata[:file_modifications] = repl.modifications.map do |mod|
          { path: mod[:relative_path], timestamp: mod[:timestamp] }
        end
      end
      cache_stats = @sub_call_cache.stats
      metadata[:sub_call_cache] = cache_stats if cache_stats[:hits] > 0 || cache_stats[:misses] > 0
      metadata[:budget] = @budget_tracker.stats if @budget_tracker

      result = CompletionResult.new(
        response: final_answer,
        execution_time: execution_time,
        usage_summary: usage_summary,
        root_model: @model_name,
        metadata: metadata
      )
      log_event(type: "run_end", run_id: run_id, execution_time: execution_time, usage: usage_summary.to_h)
      verbose_log("run_end", "depth=#{@depth} run_id=#{run_id} execution_time=#{format('%.2f', execution_time)}s usage=#{usage_summary.to_h}")
      result
    ensure
      repl&.shutdown if defined?(repl) && repl.respond_to?(:shutdown)
      @current_run_id = nil
    end

    private

    def validate_config!
      environment = @environment.to_s
      unless %w[local docker].include?(environment)
        raise ConfigurationError, "Unsupported environment: #{@environment.inspect}. Use 'local' or 'docker'"
      end
      validate_docker_options! if environment == "docker"
      raise ConfigurationError, "model_name is required" if @model_name.to_s.strip.empty?
      raise ConfigurationError, "max_depth must be >= 0" if @max_depth.to_i.negative?
      raise ConfigurationError, "max_iterations must be > 0" unless @max_iterations.to_i.positive?
      raise ConfigurationError, "max_messages must be >= 4" unless @max_messages.to_i >= 4
      raise ConfigurationError, "compaction_threshold must be between 0.1 and 1.0" unless
        @compactor.threshold.between?(0.1, 1.0)
    end

    def validate_docker_options!
      options = normalize_environment_options
      allowed = %i[
        image memory_limit cpu_quota network_mode allow_network connect_timeout
        gemini_api_key_secret gemini_api_key_secret_path keep_alive reuse_container_id
      ]
      unknown = options.keys - allowed
      raise ConfigurationError, "Unknown environment_options: #{unknown.join(', ')}" unless unknown.empty?

      if options.key?(:image) && options[:image].to_s.strip.empty?
        raise ConfigurationError, "image must be a non-empty string"
      end
      if options.key?(:memory_limit) && !options[:memory_limit].to_s.match?(/\A\d+(?:\.\d+)?[kmgKMG]?\z/)
        raise ConfigurationError, "memory_limit must be a string like '256m'"
      end
      if options.key?(:cpu_quota) && options[:cpu_quota].to_i <= 0
        raise ConfigurationError, "cpu_quota must be a positive integer"
      end
      if options.key?(:network_mode) && !%w[none bridge].include?(options[:network_mode].to_s)
        raise ConfigurationError, "network_mode must be 'none' or 'bridge'"
      end
      if options.key?(:allow_network) && ![true, false].include?(options[:allow_network])
        raise ConfigurationError, "allow_network must be true or false"
      end
      if options.key?(:connect_timeout) && options[:connect_timeout].to_i <= 0
        raise ConfigurationError, "connect_timeout must be a positive integer"
      end
      if options.key?(:gemini_api_key_secret) && options[:gemini_api_key_secret].to_s.strip.empty?
        raise ConfigurationError, "gemini_api_key_secret must be a non-empty string"
      end
      if options.key?(:gemini_api_key_secret_path)
        path = options[:gemini_api_key_secret_path].to_s
        if path.strip.empty?
          raise ConfigurationError, "gemini_api_key_secret_path must be a non-empty string when provided"
        end
      end
    end

    def build_backend_client(model_name:)
      case @backend
      when "gemini"
        Backends::GeminiRest.new(
          model_name: model_name,
          api_key: @api_key,
          **@backend_options
        )
      else
        raise ConfigurationError, "Unsupported backend: #{@backend.inspect}"
      end
    end

    def build_repl(prompt)
      if @environment.to_s == "docker"
        Repl::DockerRepl.new(
          context: prompt,
          llm_query_proc: method(:llm_query),
          timeout_seconds: @iteration_timeout,
          model_name: @model_name,
          **normalize_environment_options
        )
      else
        Repl::LocalRepl.new(
          context: prompt,
          llm_query_proc: method(:llm_query),
          timeout_seconds: @iteration_timeout
        )
      end
    end

    def normalize_environment_options
      raw = @environment_options || {}
      return {} if raw.empty?
      raise ConfigurationError, "environment_options must be a Hash" unless raw.is_a?(Hash)

      raw.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }
    end

    def initial_messages(prompt:, root_prompt:)
      [
        {
          role: "system",
          content: Prompts::SystemPrompt.build(
            root_prompt: root_prompt,
            execution_environment: @environment,
            environment_options: normalize_environment_options
          )
        },
        { role: "user", content: context_summary_prompt(prompt) }
      ]
    end

    CONTINUATION_NEW_REQUEST_MARKER = "New request: "

    def context_summary_prompt(prompt)
      if prompt.is_a?(String) && prompt.include?(CONTINUATION_NEW_REQUEST_MARKER)
        continuation_context_prompt(prompt)
      else
        summary = truncate(summarize_for_llm(prompt, depth: 0, max_depth: 3), 6000)
        <<~TEXT
          Context summary (for orientation only; full data remains available in REPL variable `context`):
          #{summary}
        TEXT
      end
    end

    def continuation_context_prompt(prompt)
      # Extract the new request from the end of the continuation prompt
      marker_idx = prompt.rindex(CONTINUATION_NEW_REQUEST_MARKER)
      new_request = prompt[(marker_idx + CONTINUATION_NEW_REQUEST_MARKER.length)..].strip
      history_section = prompt[0, marker_idx].strip

      <<~TEXT
        You are continuing from a previous RLM session.
        The REPL state (variables, requires) does NOT persist — you must re-establish any needed state.
        The full session context string is available in REPL variable `context` for reference.

        YOUR NEW TASK: #{new_request}

        Previous session context (for reference only — focus on the new task above):
        #{truncate(history_section, 4000)}
      TEXT
    end

    def request_action(messages:, usage_summary:)
      response =
        if @streaming && @backend_client.respond_to?(:stream_complete)
          request_action_streaming(messages: messages)
        else
          request_action_blocking(messages: messages)
        end
      usage_summary.add(response[:usage], model: @model_name)
      charge_budget(response[:usage])
      raw_text = response.fetch(:text).to_s
      action = @action_parser.parse(raw_text)
      {
        action: action,
        raw_text: raw_text,
        latency_s: response[:latency_s],
        repaired: false,
        usage: response[:usage]
      }
    rescue ParseError
      verbose_block("malformed_action_response", raw_text.to_s)
      repair_messages = messages + [
        { role: "assistant", content: raw_text.to_s },
        { role: "user", content: Prompts::SystemPrompt.malformed_response_repair }
      ]
      repaired = request_action_blocking(messages: repair_messages)
      usage_summary.add(repaired[:usage], model: @model_name)
      charge_budget(repaired[:usage])
      repaired_raw = repaired.fetch(:text).to_s
      action = @action_parser.parse(repaired_raw)
      verbose_block("repaired_action_response", repaired_raw)
      {
        action: action,
        raw_text: repaired_raw,
        latency_s: repaired[:latency_s],
        repaired: true,
        usage: repaired[:usage]
      }
    end

    def request_action_blocking(messages:)
      if backend_supports_on_retry?(:complete)
        @backend_client.complete(
          messages: messages,
          generation_config: @generation_config,
          on_retry: method(:log_backend_retry)
        )
      else
        @backend_client.complete(messages: messages, generation_config: @generation_config)
      end
    end

    def request_action_streaming(messages:)
      if backend_supports_on_retry?(:stream_complete)
        @backend_client.stream_complete(
          messages: messages,
          generation_config: @generation_config,
          on_retry: method(:log_backend_retry)
        ) do |chunk, accumulated|
          log_event(
            type: "chunk",
            run_id: @current_run_id,
            chunk: chunk,
            accumulated: truncate(accumulated.to_s, 2000)
          )
        end
      else
        @backend_client.stream_complete(messages: messages, generation_config: @generation_config) do |chunk, accumulated|
          log_event(
            type: "chunk",
            run_id: @current_run_id,
            chunk: chunk,
            accumulated: truncate(accumulated.to_s, 2000)
          )
        end
      end
    end

    def backend_supports_on_retry?(method_name)
      method = @backend_client.method(method_name)
      method.parameters.any? { |kind, name| [:key, :keyreq].include?(kind) && name == :on_retry }
    rescue NameError
      false
    end

    def log_backend_retry(retry_info)
      payload = {
        type: "backend_retry",
        run_id: @current_run_id
      }.merge(retry_info || {})
      log_event(payload)
      verbose_log(
        "backend_retry",
        "provider=#{payload[:provider]} mode=#{payload[:mode]} attempt=#{payload[:attempt]} next_attempt=#{payload[:next_attempt]} backoff=#{format('%.2f', payload[:backoff_seconds].to_f)}s status=#{payload[:status_code] || '-'}"
      )
    end

    def force_final(messages:, usage_summary:)
      forced_messages = messages + [{ role: "user", content: Prompts::SystemPrompt.force_final }]
      turn = request_action(messages: forced_messages, usage_summary: usage_summary)
      action = turn.fetch(:action)
      answer =
        if action[:action] == "final"
          action.fetch(:answer)
        else
          turn.fetch(:raw_text)
        end

      {
        answer: answer,
        iteration_data: {
          iteration: @max_iterations + 1,
          action: "forced_final",
          answer: answer,
          latency_s: turn[:latency_s],
          repaired: turn[:repaired] || false
        }
      }
    rescue ParseError => e
      {
        answer: "Unable to produce final structured response: #{e.message}",
        iteration_data: {
          iteration: @max_iterations + 1,
          action: "forced_final_error",
          error: e.message
        }
      }
    end

    def execution_feedback(execution_result)
      payload = {
        ok: execution_result.ok,
        stdout: truncate(execution_result.stdout.to_s, 1200),
        stderr: truncate(execution_result.stderr.to_s, 1200),
        value_preview: truncate(execution_result.value_preview.to_s, 800),
        error_class: execution_result.error_class,
        error_message: execution_result.error_message,
        backtrace_excerpt: execution_result.backtrace_excerpt
      }
      payload.delete_if { |_key, value| value.nil? }

      <<~TEXT
        Execution result:
        #{JSON.pretty_generate(payload)}

        Decide next step. Return only one JSON object in action format.
      TEXT
    end

    def llm_query(sub_prompt, model_name: nil)
      effective_model = model_name || @subcall_model || @model_name

      # Check sub-call cache
      cached = @sub_call_cache.get(sub_prompt, model_name: effective_model)
      if cached
        verbose_log("subcall_cache_hit", "model=#{effective_model} prompt=#{truncate(sub_prompt.to_s, 100)}")
        return cached
      end

      # Check budget before making a subcall
      if @budget_tracker
        begin
          @budget_tracker.check_subcall!
        rescue BudgetExceededError => e
          verbose_log("budget_exceeded", e.message)
          return "[Budget exceeded: #{e.message}]"
        end
      end

      if @depth < @max_depth
        verbose_log(
          "subcall_start",
          "parent_depth=#{@depth} child_depth=#{@depth + 1} model=#{effective_model} prompt=#{truncate(sub_prompt.to_s, 200)}"
        )
        child = self.class.new(
          backend: @backend,
          model_name: effective_model,
          api_key: @api_key,
          max_depth: @max_depth,
          max_iterations: @max_iterations,
          depth: @depth + 1,
          logger: @logger,
          verbose: @verbose,
          streaming: @streaming,
          generation_config: @generation_config,
          backend_options: @backend_options,
          environment: @environment,
          environment_options: @environment_options,
          iteration_timeout: @iteration_timeout,
          subcall_model: @subcall_model,
          budget_tracker: @budget_tracker,
          parent_run_id: @current_run_id,
          run_metadata: {},
          backend_client: effective_model == @model_name ? @backend_client : nil
        )
        child_result = child.completion(prompt: sub_prompt, root_prompt: "Recursive sub-call. Solve only this scoped sub-problem.")
        episode_result = build_episode_result(child_result)
        verbose_block("subcall_end", episode_result)
        @sub_call_cache.put(sub_prompt, model_name: effective_model, response: episode_result)
        return episode_result
      end

      verbose_log("subcall_fallback", "depth=#{@depth} max_depth=#{@max_depth} using single-shot completion")
      plain_backend =
        if effective_model != @model_name
          build_backend_client(model_name: effective_model)
        else
          @backend_client
        end
      subcall_messages = [
        { role: "system", content: "Answer clearly and concisely." },
        { role: "user", content: sub_prompt.to_s }
      ]
      subcall_config = @generation_config.merge(response_mime_type: "text/plain")
      response =
        if @streaming && plain_backend.respond_to?(:stream_complete)
          plain_backend.stream_complete(messages: subcall_messages, generation_config: subcall_config) do |chunk, accumulated|
            log_event(
              type: "chunk",
              run_id: @current_run_id,
              source: "llm_query",
              chunk: chunk,
              accumulated: truncate(accumulated.to_s, 2000)
            )
          end
        else
          plain_backend.complete(messages: subcall_messages, generation_config: subcall_config)
        end
      text = response.fetch(:text).to_s
      verbose_block("subcall_fallback_answer", text)
      @sub_call_cache.put(sub_prompt, model_name: effective_model, response: text)
      text
    end

    def log_event(payload)
      return unless @logger
      return unless @logger.respond_to?(:log)

      @logger.log(payload)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def verbose_log(tag, message)
      return unless @verbose

      puts("[rubyrlm] #{tag}: #{message}")
    end

    def verbose_block(tag, body)
      return unless @verbose

      puts("[rubyrlm] #{tag}:\n#{indent_multiline(truncate(body.to_s, 2000))}")
    end

    def verbose_execution(execution)
      return unless @verbose

      if execution.ok
        summary = {
          ok: true,
          stdout: truncate(execution.stdout.to_s, 1200),
          stderr: truncate(execution.stderr.to_s, 1200),
          value_preview: truncate(execution.value_preview.to_s, 300)
        }
        verbose_block("exec_result", JSON.pretty_generate(summary))
      else
        summary = {
          ok: false,
          error_class: execution.error_class,
          error_message: execution.error_message,
          stdout: truncate(execution.stdout.to_s, 1200),
          stderr: truncate(execution.stderr.to_s, 1200),
          backtrace_excerpt: execution.backtrace_excerpt
        }
        verbose_block("exec_result", JSON.pretty_generate(summary))
      end
    end

    def build_episode_result(child_result)
      iterations = child_result.metadata[:iterations] || []
      episode = generate_episode_summary(iterations)
      EpisodeResult.new(
        child_result.response,
        episode: episode,
        iterations: iterations.length,
        forced_final: child_result.metadata[:forced_final] || false
      )
    rescue StandardError => e
      verbose_log("episode_error", "failed to generate episode: #{e.message}")
      EpisodeResult.new(child_result.response, iterations: (child_result.metadata[:iterations] || []).length)
    end

    def generate_episode_summary(iterations)
      return nil if iterations.empty?

      parts = iterations.map do |iter|
        case iter[:action]
        when "exec"
          exec_data = iter[:execution] || {}
          status = exec_data[:ok] ? "ok" : "error: #{exec_data[:error_class]}"
          "Step #{iter[:iteration]}: exec `#{truncate(iter[:code].to_s, 100)}` → #{status}"
        when "final"
          "Step #{iter[:iteration]}: final answer"
        when "forced_final"
          "Step #{iter[:iteration]}: forced final (iteration limit)"
        else
          "Step #{iter[:iteration]}: #{iter[:action]}"
        end
      end

      parts.join("\n")
    end

    def build_budget_tracker(budget)
      return nil if budget.nil? || (budget.is_a?(Hash) && budget.empty?)

      opts = budget.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      BudgetTracker.new(**opts)
    end

    def charge_budget(usage_hash)
      return unless @budget_tracker
      return unless usage_hash.is_a?(Hash)

      tokens = Integer(usage_hash[:total_tokens] || usage_hash["total_tokens"] || 0)
      cost = Pricing.cost_for(
        model: @model_name,
        input_tokens: Integer(usage_hash[:prompt_tokens] || usage_hash["prompt_tokens"] || 0),
        cached_tokens: Integer(usage_hash[:cached_content_tokens] || usage_hash["cached_content_tokens"] || 0),
        output_tokens: Integer(usage_hash[:candidate_tokens] || usage_hash["candidate_tokens"] || 0)
      )
      @budget_tracker.add_usage(tokens: tokens, cost: cost)
    rescue BudgetExceededError => e
      verbose_log("budget_exceeded", e.message)
    end

    def indent_multiline(text)
      text.lines.map { |line| "  #{line}" }.join
    end

    def maybe_compact_and_truncate!(messages, metadata:, usage_summary:)
      result = @compactor.maybe_compact!(messages)
      if result.compacted
        usage_summary.add(result.usage, model: @compaction_model)
        metadata[:compaction_events] << {
          messages_before: result.messages_before,
          messages_after: result.messages_after,
          latency_s: result.latency_s,
          model: @compaction_model
        }
        verbose_log(
          "compaction",
          "compacted #{result.messages_before} -> #{result.messages_after} messages in #{format('%.2f', result.latency_s)}s"
        )
      end
      truncate_messages!(messages)
    rescue CompactionError => e
      verbose_log("compaction_error", "falling back to truncation: #{e.message}")
      log_event(type: "compaction_error", run_id: @current_run_id, error: e.message)
      truncate_messages!(messages)
    end

    def truncate_messages!(messages)
      return if messages.length <= @max_messages

      system_message = messages[0]
      first_user_message = messages[1]
      tail = messages.drop(2).last(@max_messages - 2)
      messages.replace([system_message, first_user_message, *tail])
    end

    def truncate(text, max_chars)
      return text if text.length <= max_chars

      "#{text[0, max_chars]}...<truncated>"
    end

    def summarize_for_llm(value, depth:, max_depth:)
      case value
      when Hash
        return "Hash(size=#{value.size})" if depth >= max_depth

        pairs = value.first(20).map do |key, nested|
          "#{key.inspect}=>#{summarize_for_llm(nested, depth: depth + 1, max_depth: max_depth)}"
        end
        extra = value.size > 20 ? ", ... #{value.size - 20} more keys" : ""
        "Hash(size=#{value.size}, keys={#{pairs.join(', ')}#{extra}})"
      when Array
        return "Array(size=#{value.size})" if depth >= max_depth

        sample = value.first(3).map do |item|
          summarize_for_llm(item, depth: depth + 1, max_depth: max_depth)
        end
        extra = value.size > 3 ? ", ... #{value.size - 3} more items" : ""
        "Array(size=#{value.size}, sample=[#{sample.join(', ')}#{extra}])"
      when String
        "String(length=#{value.length}, preview=#{truncate(value.inspect, 300)})"
      when Numeric, TrueClass, FalseClass, NilClass, Symbol
        value.inspect
      else
        "#{value.class}(#{truncate(value.to_s, 200)})"
      end
    end
  end
end
