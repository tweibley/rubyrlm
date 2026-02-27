require "spec_helper"
require "tmpdir"
require "json"
require "time"

require_relative "../lib/rubyrlm/web/services/session_loader"

RSpec.describe RubyRLM::Web::Services::SessionLoader do
  it "builds recursion tree the same with id and id.jsonl" do
    Dir.mktmpdir("rubyrlm-session-loader") do |dir|
      root_id = "root_run_123"
      child_id = "child_run_456"
      root_events = [
        { type: "run_start", run_id: root_id, model: "gemini-2.5-flash", timestamp: "2026-02-01T00:00:00Z" },
        { type: "run_end", execution_time: 1.0, usage: { prompt_tokens: 1, candidate_tokens: 1, total_tokens: 2, calls: 1 }, timestamp: "2026-02-01T00:00:01Z" }
      ]
      child_events = [
        { type: "run_start", run_id: child_id, parent_run_id: root_id, model: "gemini-2.5-flash", timestamp: "2026-02-01T00:00:02Z" },
        { type: "run_end", execution_time: 1.0, usage: { prompt_tokens: 1, candidate_tokens: 1, total_tokens: 2, calls: 1 }, timestamp: "2026-02-01T00:00:03Z" }
      ]

      File.write(File.join(dir, "#{root_id}.jsonl"), root_events.map { |event| JSON.generate(event) }.join("\n"))
      File.write(File.join(dir, "#{child_id}.jsonl"), child_events.map { |event| JSON.generate(event) }.join("\n"))

      loader = described_class.new(log_dir: dir)
      tree_plain = loader.build_recursion_tree(root_id)
      tree_with_suffix = loader.build_recursion_tree("#{root_id}.jsonl")

      expect(tree_plain[:id]).to eq(root_id)
      expect(tree_plain[:children].map { |c| c[:id] }).to include(child_id)
      expect(tree_with_suffix).to eq(tree_plain)
    end
  end

  it "aggregates usage and execution time across continued runs in one session file" do
    Dir.mktmpdir("rubyrlm-session-loader") do |dir|
      run_id = "session_abc123"
      path = File.join(dir, "#{run_id}.jsonl")

      events = [
        { type: "run_start", run_id: run_id, model: "gemini-2.5-flash", timestamp: "2026-02-01T00:00:00Z", prompt: "original" },
        { type: "iteration", data: { iteration: 1, action: "exec", execution: { ok: true } } },
        { type: "run_end", execution_time: 1.2, usage: { prompt_tokens: 10, candidate_tokens: 5, total_tokens: 15, calls: 1 }, timestamp: "2026-02-01T00:00:02Z" },
        { type: "run_start", run_id: run_id, model: "gemini-2.5-flash", timestamp: "2026-02-01T00:05:00Z", prompt: "continued" },
        { type: "iteration", data: { iteration: 2, action: "final", answer: "done" } },
        { type: "run_end", execution_time: 2.8, usage: { prompt_tokens: 20, candidate_tokens: 10, total_tokens: 30, calls: 2 }, timestamp: "2026-02-01T00:05:05Z" }
      ]

      File.write(path, events.map { |event| JSON.generate(event) }.join("\n"))

      loader = described_class.new(log_dir: dir)
      sessions = loader.list_sessions
      expect(sessions.length).to eq(1)

      summary = sessions.first
      expect(summary[:id]).to eq(run_id)
      expect(summary[:execution_time]).to eq(4.0)
      expect(summary[:prompt_tokens]).to eq(30)
      expect(summary[:candidate_tokens]).to eq(15)
      expect(summary[:total_tokens]).to eq(45)
      expect(summary[:calls]).to eq(3)
      expect(summary[:timestamp]).to eq("2026-02-01T00:05:05Z")
      expect(summary[:latest_continuation_mode]).to eq("new")
    end
  end

  it "returns aggregated run_end in loaded session" do
    Dir.mktmpdir("rubyrlm-session-loader") do |dir|
      run_id = "session_xyz789"
      path = File.join(dir, "#{run_id}.jsonl")
      events = [
        { type: "run_start", run_id: run_id, model: "gemini-2.5-flash", timestamp: "2026-02-01T00:00:00Z", prompt: "p1" },
        { type: "run_end", execution_time: 1.0, usage: { prompt_tokens: 1, candidate_tokens: 2, total_tokens: 3, calls: 1 }, timestamp: "2026-02-01T00:00:01Z" },
        { type: "run_start", run_id: run_id, model: "gemini-2.5-flash", timestamp: "2026-02-01T00:10:00Z", prompt: "p2" },
        { type: "run_end", execution_time: 2.0, usage: { prompt_tokens: 4, candidate_tokens: 5, total_tokens: 9, calls: 2 }, timestamp: "2026-02-01T00:10:02Z" }
      ]
      File.write(path, events.map { |event| JSON.generate(event) }.join("\n"))

      loader = described_class.new(log_dir: dir)
      session = loader.load_session(run_id)
      expect(session).not_to be_nil
      expect(session[:run_end][:execution_time]).to eq(3.0)
      expect(session[:run_end][:usage]).to eq(
        prompt_tokens: 5,
        candidate_tokens: 7,
        cached_content_tokens: 0,
        total_tokens: 12,
        calls: 3
      )
    end
  end

  it "exposes latest_run_start metadata for continuation badges" do
    Dir.mktmpdir("rubyrlm-session-loader") do |dir|
      run_id = "session_mode_test"
      path = File.join(dir, "#{run_id}.jsonl")
      events = [
        { type: "run_start", run_id: run_id, model: "gemini-2.5-flash", continuation_mode: "new", timestamp: "2026-02-01T00:00:00Z", prompt: "p1" },
        { type: "run_end", execution_time: 1.0, usage: { prompt_tokens: 1, candidate_tokens: 1, total_tokens: 2, calls: 1 }, timestamp: "2026-02-01T00:00:01Z" },
        { type: "run_start", run_id: run_id, model: "gemini-2.5-flash", continuation_mode: "append", source_session_id: run_id, timestamp: "2026-02-01T00:10:00Z", prompt: "p2" },
        { type: "run_end", execution_time: 2.0, usage: { prompt_tokens: 1, candidate_tokens: 1, total_tokens: 2, calls: 1 }, timestamp: "2026-02-01T00:10:03Z" }
      ]
      File.write(path, events.map { |event| JSON.generate(event) }.join("\n"))

      loader = described_class.new(log_dir: dir)
      session = loader.load_session(run_id)
      summary = loader.list_sessions.first

      expect(session[:latest_run_start][:continuation_mode]).to eq("append")
      expect(session[:latest_run_start][:source_session_id]).to eq(run_id)
      expect(summary[:latest_continuation_mode]).to eq("append")
    end
  end

  it "handles invalid utf-8 bytes in jsonl logs" do
    Dir.mktmpdir("rubyrlm-session-loader") do |dir|
      run_id = "encoding_case"
      path = File.join(dir, "#{run_id}.jsonl")
      event = JSON.generate({ type: "run_start", run_id: run_id, model: "gemini-2.5-flash", timestamp: "2026-02-01T00:00:00Z", prompt: "ok" })
      bad_line = (event + "\xC3").b
      File.binwrite(path, bad_line)

      loader = described_class.new(log_dir: dir)
      sessions = loader.list_sessions

      expect(sessions.length).to eq(1)
      expect(sessions.first[:id]).to eq(run_id)
    end
  end

  it "deletes a session log file by session id" do
    Dir.mktmpdir("rubyrlm-session-loader") do |dir|
      run_id = "delete_case"
      path = File.join(dir, "#{run_id}.jsonl")
      File.write(path, JSON.generate({ type: "run_start", run_id: run_id, timestamp: "2026-02-01T00:00:00Z" }))

      loader = described_class.new(log_dir: dir)

      expect(loader.delete_session(run_id)).to be(true)
      expect(File.exist?(path)).to be(false)
      expect(loader.load_session(run_id)).to be_nil
      expect(loader.delete_session(run_id)).to be(false)
    end
  end
end
