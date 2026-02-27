require "json"
require "fileutils"
require "time"

module RubyRLM
  module Web
    module Services
      class SessionLoader
        def initialize(log_dir:)
          @log_dir = log_dir
          FileUtils.mkdir_p(@log_dir)
        end

        def list_sessions
          Dir.glob(File.join(@log_dir, "*.jsonl")).map do |path|
            summarize_file(path)
          end.compact.sort_by { |s| s[:timestamp] || "" }.reverse
        end

        def load_session(session_id)
          path = resolve_path(session_id)
          return nil unless path && File.exist?(path)

          events = parse_jsonl(path)
          build_session(events, File.basename(path))
        end

        def raw_session(session_id)
          path = resolve_path(session_id)
          return nil unless path && File.exist?(path)

          File.read(path)
        end

        def delete_session(session_id)
          path = resolve_path(session_id)
          return false unless path && File.exist?(path)

          File.delete(path)
          true
        rescue Errno::ENOENT
          false
        end

        def build_recursion_tree(run_id, by_parent: nil)
          normalized_id = normalize_session_id(run_id)
          return { id: nil, children: [] } if normalized_id.nil?

          tree = { id: normalized_id, children: [] }
          by_parent ||= list_sessions.group_by { |s| s[:parent_run_id] }

          Array(by_parent[normalized_id]).each do |s|
            child_tree = build_recursion_tree(s[:id], by_parent: by_parent)
            tree[:children] << child_tree.merge(
              model: s[:model],
              iterations: s[:iterations],
              errors: s[:errors],
              timestamp: s[:timestamp]
            )
          end

          tree
        end

        def aggregate_analytics(since_time: nil)
          sessions = list_sessions
          if since_time
            # Keep only sessions where timestamp is >= since_time (e.g. "2026-02-27T12:00:00Z" >= "2026-02-27...")
            iso_since = since_time.utc.iso8601
            sessions = sessions.select { |s| s[:timestamp] && s[:timestamp] >= iso_since }
          end
          return empty_analytics if sessions.empty?

          total_iterations = 0
          total_tokens = 0
          total_prompt_tokens = 0
          total_candidate_tokens = 0
          total_errors = 0
          total_latency = 0.0
          total_repairs = 0
          total_exec_steps = 0
          total_cost = 0.0
          model_breakdown = Hash.new { |h, k| h[k] = { sessions: 0, tokens: 0, cost: 0.0 } }
          error_classes = Hash.new(0)
          daily_data = Hash.new { |h, k| h[k] = { sessions: 0, tokens: 0, prompt_tokens: 0, candidate_tokens: 0, cached_content_tokens: 0, cost: 0.0 } }

          sessions.each do |s|
            total_iterations += s[:iterations]
            total_tokens += s[:total_tokens]
            total_prompt_tokens += s[:prompt_tokens]
            total_candidate_tokens += s[:candidate_tokens]
            total_errors += s[:errors]
            session_cost = s[:total_cost] || 0.0
            total_cost += session_cost

            model_breakdown[s[:model]][:sessions] += 1
            model_breakdown[s[:model]][:tokens] += s[:total_tokens]
            model_breakdown[s[:model]][:cost] += session_cost

            date = s[:timestamp] ? s[:timestamp][0..9] : "unknown"
            daily_data[date][:sessions] += 1
            daily_data[date][:tokens] += s[:total_tokens]
            daily_data[date][:cost] += session_cost

            path = resolve_path(s[:id])
            next unless path

            each_iteration_data(path) do |data|
              total_latency += data[:latency_s].to_f
              total_repairs += 1 if data[:repaired]
              total_exec_steps += 1 if data[:action] == "exec"

              if data[:execution] && !data[:execution][:ok]
                ec = data[:execution][:error_class] || "Unknown"
                error_classes[ec] += 1
              end

              # Track per-day token breakdown
              if data[:usage]
                daily_data[date][:prompt_tokens] += data[:usage][:prompt_tokens].to_i
                daily_data[date][:candidate_tokens] += data[:usage][:candidate_tokens].to_i
                daily_data[date][:cached_content_tokens] += data[:usage][:cached_content_tokens].to_i
              end
            end
          end

          avg_iterations = sessions.empty? ? 0 : (total_iterations.to_f / sessions.size).round(1)
          avg_latency = total_exec_steps.zero? ? 0 : (total_latency / (total_iterations)).round(2)
          success_rate = total_exec_steps.zero? ? 100 : (((total_exec_steps - total_errors).to_f / total_exec_steps) * 100).round(1)
          repair_rate = total_iterations.zero? ? 0 : ((total_repairs.to_f / total_iterations) * 100).round(1)

          {
            total_sessions: sessions.size,
            total_iterations: total_iterations,
            total_tokens: total_tokens,
            total_prompt_tokens: total_prompt_tokens,
            total_candidate_tokens: total_candidate_tokens,
            total_cost: total_cost.round(6),
            avg_iterations_per_session: avg_iterations,
            avg_latency_per_iteration: avg_latency,
            success_rate: success_rate,
            repair_rate: repair_rate,
            model_breakdown: model_breakdown,
            top_error_classes: error_classes.sort_by { |_, v| -v }.first(10).to_h,
            time_series: daily_data.sort.map { |date, data|
              {
                date: date,
                sessions: data[:sessions],
                tokens: data[:tokens],
                prompt_tokens: data[:prompt_tokens] || 0,
                candidate_tokens: data[:candidate_tokens] || 0,
                cached_content_tokens: data[:cached_content_tokens] || 0,
                cost: (data[:cost] || 0.0).round(6)
              }
            }
          }
        end

        def compare_sessions(id1, id2)
          s1 = load_session(id1)
          s2 = load_session(id2)
          return nil unless s1 && s2

          { session_a: s1, session_b: s2 }
        end

        private

        def resolve_path(session_id)
          # Accept either a run_id (UUID) or filename
          clean = File.basename(session_id.to_s)
          return nil if clean.include?("/") || clean.include?("\\")

          path = if clean.end_with?(".jsonl")
            File.join(@log_dir, clean)
          else
            File.join(@log_dir, "#{clean}.jsonl")
          end

          File.exist?(path) ? path : nil
        end

        def normalize_session_id(session_id)
          value = session_id.to_s.strip
          return nil if value.empty?

          clean = File.basename(value)
          return nil if clean.include?("/") || clean.include?("\\")

          clean.end_with?(".jsonl") ? clean.delete_suffix(".jsonl") : clean
        end

        def parse_jsonl(path)
          read_jsonl_lines(path).filter_map do |line|
            line = line.strip
            next if line.empty?
            JSON.parse(line, symbolize_names: true)
          rescue JSON::ParserError
            nil
          end
        end

        def read_jsonl_lines(path)
          Enumerator.new do |yielder|
            File.open(path, "rb") do |file|
              file.each_line do |line|
                safe_line = line.force_encoding(Encoding::UTF_8)
                safe_line = safe_line.scrub("") unless safe_line.valid_encoding?
                yielder << safe_line
              end
            end
          end
        end

        def summarize_file(path)
          events = parse_jsonl(path)
          return nil if events.empty?

          run_starts = events.select { |e| e[:type] == "run_start" }
          run_ends = events.select { |e| e[:type] == "run_end" }
          run_start = run_starts.first
          latest_run_start = run_starts.last
          iterations = events.select { |e| e[:type] == "iteration" }

          error_count = iterations.count do |it|
            data = it[:data] || it
            data[:action] == "exec" && data[:execution] && !data[:execution][:ok]
          end

          run_id = run_start&.dig(:run_id) || File.basename(path, ".jsonl")
          usage = aggregate_usage(run_ends.map { |e| e[:usage] })
          total_execution_time = run_ends.sum { |e| e[:execution_time].to_f }
          latest_timestamp = run_ends.last&.dig(:timestamp) || run_starts.last&.dig(:timestamp)

          model = run_start&.dig(:model) || "unknown"
          session_cost = RubyRLM::Pricing.cost_for(
            model: model,
            input_tokens: usage[:prompt_tokens] || 0,
            cached_tokens: usage[:cached_content_tokens] || 0,
            output_tokens: usage[:candidate_tokens] || 0
          )

          {
            id: run_id,
            filename: File.basename(path),
            timestamp: latest_timestamp,
            model: model,
            prompt: run_start&.dig(:prompt),
            latest_continuation_mode: latest_run_start&.dig(:continuation_mode) || "new",
            parent_run_id: run_start&.dig(:parent_run_id),
            container_id: run_start&.dig(:container_id),
            depth: run_start&.dig(:depth) || 0,
            iterations: iterations.size,
            errors: error_count,
            has_recursion: run_start&.dig(:parent_run_id) != nil,
            execution_time: total_execution_time,
            prompt_tokens: usage[:prompt_tokens] || 0,
            candidate_tokens: usage[:candidate_tokens] || 0,
            cached_content_tokens: usage[:cached_content_tokens] || 0,
            total_tokens: usage[:total_tokens] || 0,
            total_cost: session_cost.round(6),
            calls: usage[:calls] || 0
          }
        end

        def build_session(events, filename)
          run_starts = events.select { |e| e[:type] == "run_start" }
          run_ends = events.select { |e| e[:type] == "run_end" }
          run_start = run_starts.first
          latest_run_start = run_starts.last
          run_end = aggregate_run_end(run_ends)
          iterations = events.select { |e| e[:type] == "iteration" }

          error_count = 0
          success_count = 0
          submit_count = 0

          iterations.each do |it|
            data = it[:data] || it
            action = data[:action]
            if action == "final" || action == "forced_final"
              submit_count += 1
            elsif data[:execution] && !data[:execution][:ok]
              error_count += 1
            else
              success_count += 1
            end
          end

          {
            filename: filename,
            run_start: run_start,
            latest_run_start: latest_run_start,
            run_end: run_end,
            iterations: iterations,
            stats: {
              total: iterations.size,
              success: success_count,
              errors: error_count,
              submits: submit_count
            }
          }
        end

        def aggregate_usage(usages)
          values = Array(usages).compact
          return { prompt_tokens: 0, candidate_tokens: 0, cached_content_tokens: 0, total_tokens: 0, calls: 0 } if values.empty?

          {
            prompt_tokens: values.sum { |u| u[:prompt_tokens].to_i },
            candidate_tokens: values.sum { |u| u[:candidate_tokens].to_i },
            cached_content_tokens: values.sum { |u| u[:cached_content_tokens].to_i },
            total_tokens: values.sum { |u| u[:total_tokens].to_i },
            calls: values.sum { |u| u[:calls].to_i }
          }
        end

        def aggregate_run_end(run_ends)
          values = Array(run_ends).compact
          return nil if values.empty?

          {
            type: "run_end",
            timestamp: values.last[:timestamp],
            execution_time: values.sum { |e| e[:execution_time].to_f },
            usage: aggregate_usage(values.map { |e| e[:usage] })
          }
        end

        def empty_analytics
          {
            total_sessions: 0, total_iterations: 0, total_tokens: 0,
            total_prompt_tokens: 0, total_candidate_tokens: 0, total_cost: 0.0,
            avg_iterations_per_session: 0, avg_latency_per_iteration: 0,
            success_rate: 100, repair_rate: 0,
            model_breakdown: {}, top_error_classes: {}, time_series: []
          }
        end

        def each_iteration_data(path)
          read_jsonl_lines(path).each do |line|
            line = line.strip
            next if line.empty?

            event = JSON.parse(line, symbolize_names: true)
            next unless event[:type] == "iteration"

            yield(event[:data] || event)
          rescue JSON::ParserError
            next
          end
        end
      end
    end
  end
end
