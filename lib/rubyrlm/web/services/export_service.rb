require "json"
require "tmpdir"
require "fileutils"
require "kramdown"
require "kramdown-parser-gfm"

module RubyRLM
  module Web
    module Services
      class ExportService
        def initialize(session_loader:)
          @session_loader = session_loader
        end

        def export_session(session_id, theme: "light")
          session = @session_loader.load_session(session_id)
          return nil unless session

          build_html(session, theme: theme)
        end

        def export_share_png(session_id, theme: "light")
          session = @session_loader.load_session(session_id)
          return nil unless session

          html = build_html(session, theme: theme)
          render_full_page_png(html)
        end

        private

        def render_full_page_png(html)
          chrome = find_chrome
          return nil unless chrome

          Dir.mktmpdir("rubyrlm-share") do |dir|
            html_path = File.join(dir, "session.html")
            png_path = File.join(dir, "session.png")

            # Inject script to write content height into the document title
            # so we can extract it with --dump-dom on the first pass
            instrumented = html.sub("</body>",
              "<script>document.title=document.body.scrollHeight;</script></body>")
            File.write(html_path, instrumented)

            file_url = "file://#{html_path}"

            # Pass 1: get the actual content height
            dom_output = `"#{chrome}" --headless --disable-gpu --no-sandbox --dump-dom "#{file_url}" 2>/dev/null`
            height = dom_output[/<title>(\d+)</, 1]&.to_i || 4000
            height = [height + 40, 200].max # pad bottom, enforce minimum

            # Pass 2: screenshot at the exact content height
            system(
              chrome, "--headless", "--disable-gpu", "--no-sandbox",
              "--hide-scrollbars",
              "--screenshot=#{png_path}",
              "--window-size=1200,#{height}",
              "--virtual-time-budget=3000",
              file_url,
              out: File::NULL, err: File::NULL
            )

            return nil unless File.exist?(png_path)
            File.binread(png_path)
          end
        end

        def find_chrome
          # macOS
          mac_path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
          return mac_path if File.exist?(mac_path)

          # Linux
          %w[google-chrome chromium-browser chromium].each do |cmd|
            path = `which #{cmd} 2>/dev/null`.strip
            return path unless path.empty?
          end

          nil
        end

        def build_share_card(session, theme: "light")
          rs = session[:run_start]
          re = session[:run_end]
          iterations = session[:iterations] || []
          stats = session[:stats] || {}

          model = rs&.dig(:model) || "unknown"
          prompts = []
          if rs&.dig(:prompt) && !rs[:prompt].to_s.strip.empty?
            prompts << escape(truncate_text(rs[:prompt].to_s.strip, 120))
          end
          
          iterations.each do |it|
            d = it[:data] || it
            if d[:action] == "user_prompt" && d[:prompt] && !d[:prompt].to_s.strip.empty?
              prompts << escape(truncate_text(d[:prompt].to_s.strip, 120))
            end
          end
          
          query_html = if prompts.empty?
                         ""
                       else
                         chunks = prompts.map { |p| "<div class='query-text'>#{p}</div>" }.join
                         "<div class='query-section'><div class='label'>#{prompts.size > 1 ? 'QUERIES' : 'QUERY'}</div>#{chunks}</div>"
                       end

          run_id = rs&.dig(:run_id).to_s[0..7]
          date = rs&.dig(:timestamp).to_s[0..9]
          exec_time = re&.dig(:execution_time) ? "#{re[:execution_time].round(2)}s" : "-"
          total_tokens = format_tokens(re&.dig(:usage, :total_tokens))

          # Get final answer preview
          final_it = iterations.reverse.find { |it| (it[:data] || it)[:action] == "final" }
          final_answer = if final_it
            markdown_to_html((final_it[:data] || final_it)[:answer].to_s)
          else
            "No final answer"
          end

          # Build step flow summary: icons for each step
          step_dots = iterations.map do |it|
            d = it[:data] || it
            is_final = d[:action] == "final" || d[:action] == "forced_final"
            is_error = !is_final && d[:execution] && !d[:execution][:ok]
            is_user = d[:action] == "user_prompt"
            if is_final then "final"
            elsif is_user then "user"
            elsif is_error then "error"
            else "ok"
            end
          end

          <<~HTML
<!DOCTYPE html>
<html lang="en" data-theme="#{theme}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=1200">
  <style>#{share_card_css}</style>
</head>
<body>
  <div class="card">
    <div class="card-header">
      <div class="brand">
        <span class="logo">RLM</span>
        <span class="title">RubyRLM Session</span>
      </div>
      <div class="meta">
        <span class="meta-tag">#{escape(model)}</span>
        <span class="meta-text">#{date}</span>
        <span class="meta-text">#{run_id}</span>
      </div>
    </div>

    <div class="stats-row">
      <div class="stat-pill"><span class="stat-num">#{stats[:total] || 0}</span> steps</div>
      <div class="stat-pill stat-pill--ok"><span class="stat-num">#{stats[:success] || 0}</span> ok</div>
      #{stats[:errors].to_i > 0 ? "<div class='stat-pill stat-pill--err'><span class='stat-num'>#{stats[:errors]}</span> errors</div>" : ""}
      <div class="stat-pill stat-pill--time">#{exec_time}</div>
      <div class="stat-pill stat-pill--tokens">#{total_tokens} tokens</div>
    </div>

    #{query_html}

    <div class="flow-section">
      <div class="label">EXECUTION FLOW</div>
      <div class="flow-dots">
        #{step_dots.each_with_index.map { |s, i| "<div class='dot dot--#{s}'>#{i + 1}</div><div class='dot-line#{i == step_dots.size - 1 ? " dot-line--hidden" : ""}'></div>" }.join}
      </div>
    </div>

    <div class="answer-section">
      <div class="label">ANSWER</div>
      <div class="answer-text">#{final_answer}</div>
    </div>

    <div class="card-footer">
      <span class="footer-text">Generated by RubyRLM</span>
    </div>
  </div>
</body>
</html>
          HTML
        end

        def markdown_to_html(str)
          return "" if str.nil? || str.empty?
          Kramdown::Document.new(str, input: "GFM", hard_wrap: false).to_html
        end

        def truncate_text(str, max)
          return "" if str.nil? || str.empty?
          str.length > max ? str[0, max] + "..." : str
        end

        def build_html(session, theme: "light")
          rs = session[:run_start]
          re = session[:run_end]
          iterations = session[:iterations] || []
          stats = session[:stats] || {}

          # Build the self-contained HTML
          <<~HTML
<!DOCTYPE html>
<html lang="en" data-theme="#{theme}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>RubyRLM Session: #{escape(rs&.dig(:run_id).to_s[0..7])}</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <style>#{export_css}</style>
</head>
<body>
  <div class="export-shell">
    <header class="export-header">
      <div class="export-brand">
        <span class="export-logo">RLM</span>
        <div class="export-brand-text">
          <h1>RubyRLM Session</h1>
          <p>Execution trace and final answer snapshot</p>
        </div>
      </div>
      <div class="export-meta">
        <span class="meta-pill">Run #{escape(rs&.dig(:run_id).to_s[0..7])}</span>
        <span class="meta-pill">#{escape(rs&.dig(:model).to_s)}</span>
        <span class="meta-pill">#{escape(rs&.dig(:timestamp).to_s)}</span>
      </div>
    </header>

    <section class="export-stats">
      <div class="stat">
        <div class="stat-value">#{stats[:total] || 0}</div>
        <div class="stat-label">Steps</div>
      </div>
      <div class="stat stat--success">
        <div class="stat-value">#{stats[:success] || 0}</div>
        <div class="stat-label">OK</div>
      </div>
      <div class="stat stat--error">
        <div class="stat-value">#{stats[:errors] || 0}</div>
        <div class="stat-label">Errors</div>
      </div>
      <div class="stat stat--info">
        <div class="stat-value">#{stats[:submits] || 0}</div>
        <div class="stat-label">Final</div>
      </div>
    </section>

    #{rs&.dig(:prompt) ? "<section class='export-query'><h3>Query</h3><pre>#{escape(rs[:prompt].to_s)}</pre></section>" : ""}

    <section class="export-timeline">
      <h2>Execution Timeline</h2>
      #{iterations.map { |it| render_iteration(it) }.join("\n")}
    </section>

    #{render_usage_summary(re)}

    <footer class="export-footer">
      <p>Generated by RubyRLM &middot; #{Time.now.utc.strftime("%Y-%m-%d %H:%M UTC")}</p>
    </footer>
  </div>
</body>
</html>
          HTML
        end

        def render_iteration(it)
          d = it[:data] || it
          is_submit = d[:action] == "final" || d[:action] == "forced_final"
          is_error = !is_submit && d[:execution] && !d[:execution][:ok]
          is_user_prompt = d[:action] == "user_prompt"

          content = if is_submit
            "<div class='answer'><h4>Answer</h4><div class='markdown-body'>#{markdown_to_html(d[:answer].to_s)}</div></div>"
          elsif is_user_prompt
            "<div class='answer answer--user'><h4>Follow-up Request</h4><div class='markdown-body'>#{escape(d[:prompt].to_s)}</div></div>"
          else
            code_html = "<div class='code-section'><h4>Ruby Code</h4><pre><code>#{escape(d[:code].to_s)}</code></pre></div>"
            exec_html = render_execution(d[:execution])
            code_html + exec_html
          end

          type_class = is_submit ? "step--final" : (is_user_prompt ? "step--user" : (is_error ? "step--error" : "step--ok"))
          type_badge = is_submit ? "FINAL" : (is_user_prompt ? "USER" : "EXEC")
          latency = d[:latency_s] ? "#{d[:latency_s].round(2)}s" : ""

          <<~STEP
            <div class="step #{type_class}">
              <div class="step-header">
                <span class="step-badge">Step #{d[:iteration]}</span>
                <span class="type-badge type-badge--#{is_submit ? 'final' : 'exec'}">#{type_badge}</span>
                <span class="step-latency">#{latency}</span>
              </div>
              <div class="step-body">#{content}</div>
            </div>
          STEP
        end

        def render_execution(exec)
          return "<div class='exec-out'><em>No execution data</em></div>" unless exec

          if !exec[:ok]
            cls = escape(exec[:error_class].to_s)
            msg = escape(exec[:error_message].to_s)
            "<div class='exec-out exec-out--error'><strong>#{cls}</strong><pre>#{msg}</pre></div>"
          else
            parts = []
            parts << "<div class='exec-stdout'>#{escape(exec[:stdout].to_s)}</div>" if exec[:stdout] && !exec[:stdout].empty?
            parts << "<div class='exec-value'>=&gt; #{escape(exec[:value_preview].to_s)}</div>" if exec[:value_preview] && !exec[:value_preview].empty?
            parts << "<em>No output</em>" if parts.empty?
            "<div class='exec-out'>#{parts.join}</div>"
          end
        end

        def render_usage_summary(re)
          return "" unless re && re[:usage]
          u = re[:usage]
          <<~USAGE
            <section class="export-usage">
              <h2>Run Summary</h2>
              <div class="usage-grid">
                <div class="usage-item"><div class="usage-value">#{re[:execution_time]&.round(2)}s</div><div class="usage-label">Total Time</div></div>
                <div class="usage-item"><div class="usage-value">#{u[:calls] || 0}</div><div class="usage-label">LLM Calls</div></div>
                <div class="usage-item"><div class="usage-value">#{format_tokens(u[:prompt_tokens])}</div><div class="usage-label">Prompt Tokens</div></div>
                <div class="usage-item"><div class="usage-value">#{format_tokens(u[:candidate_tokens])}</div><div class="usage-label">Candidate Tokens</div></div>
              </div>
            </section>
          USAGE
        end

        def format_tokens(n)
          return "0" unless n
          n >= 1000 ? "#{(n / 1000.0).round(1)}K" : n.to_s
        end

        def escape(str)
          str.to_s
            .gsub("&", "&amp;")
            .gsub("<", "&lt;")
            .gsub(">", "&gt;")
            .gsub('"', "&quot;")
        end

        def share_card_css
          <<~CSS
            * { box-sizing: border-box; margin: 0; padding: 0; }
            :root, :root[data-theme="dark"] {
              --bg: #0c0c0c;
              --text: #e5e5e5;
              --brand-text: #fff;
              --meta-bg: #1a1a1a;
              --meta-border: #333;
              --meta-tag: #ccc;
              --meta-text: #666;
              --stat-bg: #151515;
              --stat-border: #2a2a2a;
              --stat-label: #888;
              --stat-num: #e5e5e5;
              --label: #555;
              --query-bg: #111;
              --query-border: #222;
              --query-text: #aaa;
              --dot-line: #2a2a2a;
              --code-bg: #000;
              --code-border: #222;
              --code-text: #e2e8f0;
              --inline-code-bg: rgba(255, 255, 255, 0.1);
              --inline-code-text: #a78bfa;
              --fade: #0c0c0c;
            }
            :root[data-theme="light"] {
              --bg: #f8fafc;
              --text: #1e293b;
              --brand-text: #0f172a;
              --meta-bg: #f1f5f9;
              --meta-border: #cbd5e1;
              --meta-tag: #475569;
              --meta-text: #64748b;
              --stat-bg: #ffffff;
              --stat-border: #e2e8f0;
              --stat-label: #64748b;
              --stat-num: #0f172a;
              --label: #94a3b8;
              --query-bg: #ffffff;
              --query-border: #e2e8f0;
              --query-text: #475569;
              --dot-line: #cbd5e1;
              --code-bg: #1e293b;
              --code-border: #334155;
              --code-text: #f8fafc;
              --inline-code-bg: rgba(0, 0, 0, 0.05);
              --inline-code-text: #c026d3;
              --fade: #f8fafc;
            }

            html, body { width: 1200px; height: 1200px; overflow: hidden; }
            body { font-family: -apple-system, 'SF Pro Display', 'Helvetica Neue', sans-serif; background: var(--bg); color: var(--text); }
            .card { width: 1200px; height: 1200px; padding: 64px 72px; display: flex; flex-direction: column; position: relative; overflow: hidden; }
            .card::before { content: ''; position: absolute; top: -200px; right: -200px; width: 600px; height: 600px; background: radial-gradient(circle, rgba(16,185,129,0.08) 0%, transparent 70%); pointer-events: none; }
            .card::after { content: ''; position: absolute; bottom: -100px; left: -100px; width: 500px; height: 500px; background: radial-gradient(circle, rgba(59,130,246,0.05) 0%, transparent 70%); pointer-events: none; }

            .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 40px; }
            .brand { display: flex; align-items: center; gap: 16px; }
            .logo { background: #10b981; color: #000; padding: 8px 18px; border-radius: 8px; font-weight: 800; font-size: 22px; letter-spacing: 0.02em; }
            .title { font-size: 28px; font-weight: 700; color: var(--brand-text); letter-spacing: -0.02em; }
            .meta { display: flex; align-items: center; gap: 14px; }
            .meta-tag { background: var(--meta-bg); border: 1px solid var(--meta-border); padding: 6px 16px; border-radius: 8px; font-size: 16px; font-weight: 600; color: var(--meta-tag); font-family: 'SF Mono', ui-monospace, monospace; }
            .meta-text { font-size: 15px; color: var(--meta-text); font-family: 'SF Mono', ui-monospace, monospace; }

            .stats-row { display: flex; gap: 12px; margin-bottom: 40px; }
            .stat-pill { display: flex; align-items: center; gap: 8px; padding: 12px 24px; background: var(--stat-bg); border: 1px solid var(--stat-border); border-radius: 10px; font-size: 16px; color: var(--stat-label); font-weight: 500; }
            .stat-num { font-weight: 700; font-family: 'SF Mono', ui-monospace, monospace; color: var(--stat-num); font-size: 20px; }
            .stat-pill--ok { border-color: rgba(16,185,129,0.25); }
            .stat-pill--ok .stat-num { color: #10b981; }
            .stat-pill--err { border-color: rgba(239,68,68,0.25); }
            .stat-pill--err .stat-num { color: #ef4444; }
            .stat-pill--time { color: var(--stat-label); font-family: 'SF Mono', ui-monospace, monospace; font-weight: 600; }
            .stat-pill--tokens { color: var(--stat-label); font-family: 'SF Mono', ui-monospace, monospace; font-weight: 600; }

            .label { font-size: 13px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.1em; color: var(--label); margin-bottom: 12px; }

            .query-section { margin-bottom: 36px; }
            .query-text { font-size: 20px; color: var(--query-text); line-height: 1.5; padding: 20px 24px; background: var(--query-bg); border: 1px solid var(--query-border); border-radius: 12px; font-family: 'SF Mono', ui-monospace, monospace; margin-bottom: 12px; }
            .query-text:last-child { margin-bottom: 0; }

            .flow-section { margin-bottom: 36px; }
            .flow-dots { display: flex; align-items: center; gap: 0; }
            .dot { width: 44px; height: 44px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 16px; font-weight: 700; font-family: 'SF Mono', ui-monospace, monospace; flex-shrink: 0; }
            .dot--ok { background: #0a2e1a; color: #10b981; border: 2px solid rgba(16,185,129,0.4); }
            .dot--error { background: #2a0a0a; color: #ef4444; border: 2px solid rgba(239,68,68,0.4); }
            .dot--final { background: #0a1a2e; color: #3b82f6; border: 2px solid rgba(59,130,246,0.4); }
            .dot--user { background: rgba(168, 85, 247, 0.15); color: #c084fc; border: 2px solid rgba(168, 85, 247, 0.5); }
            .dot-line { width: 24px; height: 2px; background: var(--dot-line); flex-shrink: 0; }
            .dot-line--hidden { visibility: hidden; }

            .answer-section { flex: 1; min-height: 0; display: flex; flex-direction: column; overflow: hidden; position: relative; }
            .answer-text { flex: 1; font-size: 18px; color: var(--text); line-height: 1.6; padding: 24px 28px; background: rgba(59,130,246,0.06); border: 1px solid rgba(59,130,246,0.15); border-radius: 14px; overflow: hidden; position: relative; }
            
            /* Fade out effect string bottom */
            .answer-text::after {
              content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 120px;
              background: linear-gradient(to bottom, transparent, var(--fade)); pointer-events: none; border-radius: 0 0 14px 14px;
            }

            .answer-text > *:first-child { margin-top: 0; }
            .answer-text h1, .answer-text h2, .answer-text h3 { margin: 20px 0 10px; font-weight: 700; color: var(--brand-text); }
            .answer-text h1 { font-size: 24px; }
            .answer-text h2 { font-size: 22px; }
            .answer-text p, .answer-text ul, .answer-text ol { margin-bottom: 16px; }
            .answer-text ul, .answer-text ol { padding-left: 24px; }
            .answer-text li { margin-bottom: 6px; }
            .answer-text code { background: var(--inline-code-bg); border-radius: 6px; padding: 2px 6px; font-family: 'SF Mono', ui-monospace, monospace; font-size: 16px; color: var(--inline-code-text); }
            .answer-text pre { background: var(--code-bg); border: 1px solid var(--code-border); border-radius: 10px; padding: 16px; margin-bottom: 16px; overflow: hidden; }
            .answer-text pre code { background: none; padding: 0; border: 0; color: var(--code-text); }
            .answer-text blockquote { border-left: 4px solid #3b82f6; padding-left: 16px; color: var(--meta-text); margin-bottom: 16px; }
            .answer-text table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
            .answer-text th, .answer-text td { border: 1px solid var(--meta-border); padding: 8px 12px; text-align: left; }
            .answer-text th { background: var(--meta-bg); font-weight: 600; color: var(--meta-tag); }

            .card-footer { margin-top: auto; padding-top: 24px; }
            .footer-text { font-size: 14px; color: var(--label); font-weight: 500; }
          CSS
        end

        def export_css
          <<~CSS
            * { box-sizing: border-box; margin: 0; padding: 0; }
            :root, :root[data-theme="dark"] {
              --bg: #030712;
              --panel: rgba(17, 24, 39, 0.7);
              --panel-soft: rgba(31, 41, 55, 0.5);
              --border: rgba(55, 65, 81, 0.6);
              --text: #f3f4f6;
              --muted: #9ca3af;
              --accent: #10b981;
              --user: #a855f7;
              --ok: #10b981;
              --err: #ef4444;
              --info: #3b82f6;
              --code-bg: #000000;
              --code-border: #1f2937;
              --code-text: #e5e7eb;
              --shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
              --exec-bg: rgba(0, 0, 0, 0.4);
              --exec-text: #e5e7eb;
              --exec-stdout: #9ca3af;
              --exec-val: #60a5fa;
              --exec-err-bg: rgba(194, 59, 48, 0.06);
              --exec-err-border: rgba(194, 59, 48, 0.32);
              --exec-err-text: #8e2420;
              --exec-err-pre: #fff4f3;
              --badge-bg: rgba(0,0,0,0.2);
              --answer-bg: rgba(37, 99, 235, 0.05);
              --answer-border: rgba(37, 99, 235, 0.2);
              --answer-usr-bg: rgba(168, 85, 247, 0.05);
              --answer-usr-border: rgba(168, 85, 247, 0.2);
              --grid-pattern: rgba(255, 255, 255, 0.05);
              --mono: 'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
              --sans: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            }
            :root[data-theme="light"] {
              --bg: #eef2f7;
              --panel: rgba(255, 255, 255, 0.96);
              --panel-soft: #f7f9fc;
              --border: #d8e0eb;
              --text: #142136;
              --muted: #5f6f86;
              --accent: #0f766e;
              --user: #a855f7;
              --ok: #0f9d58;
              --err: #c23b30;
              --info: #2563eb;
              --code-bg: #101827;
              --code-border: #1f2a3f;
              --code-text: #e2e8f0;
              --shadow: 0 12px 30px rgba(16, 24, 40, 0.08);
              --exec-bg: #f8fafc;
              --exec-text: #334155;
              --exec-stdout: #64748b;
              --exec-val: #2563eb;
              --exec-err-bg: #fef2f2;
              --exec-err-border: #fecaca;
              --exec-err-text: #991b1b;
              --exec-err-pre: #fef2f2;
              --badge-bg: #e2e8f0;
              --answer-bg: rgba(37, 99, 235, 0.04);
              --answer-border: rgba(37, 99, 235, 0.2);
              --answer-usr-bg: rgba(168, 85, 247, 0.04);
              --answer-usr-border: rgba(168, 85, 247, 0.2);
              --grid-pattern: rgba(0, 0, 0, 0.05);
            }

            body {
              font-family: var(--sans);
              color: var(--text);
              background: var(--bg);
              line-height: 1.55;
              padding: 28px;
              background-image: radial-gradient(circle at 1px 1px, var(--grid-pattern) 1px, transparent 0);
              background-size: 24px 24px;
            }

            h1, h2, h3, h4 { font-weight: 700; color: var(--text); }
            pre, code { font-family: var(--mono); font-size: 12px; }
            pre {
              background: var(--code-bg);
              color: var(--code-text);
              border: 1px solid var(--code-border);
              border-radius: 12px;
              padding: 12px;
              overflow-x: auto;
              white-space: pre-wrap;
              word-break: break-word;
            }

            .export-shell {
              max-width: 1120px;
              margin: 0 auto;
              display: flex;
              flex-direction: column;
              gap: 14px;
            }

            .export-header, .export-query, .export-timeline, .export-usage, .export-footer {
              background: var(--panel);
              border: 1px solid var(--border);
              border-radius: 16px;
              box-shadow: var(--shadow);
            }

            .export-header {
              padding: 18px 20px;
              display: flex;
              justify-content: space-between;
              align-items: flex-start;
              gap: 16px;
            }

            .export-brand { display: flex; align-items: center; gap: 12px; }
            .export-logo {
              width: 44px;
              height: 44px;
              border-radius: 12px;
              border: 1px solid #9bc2ff;
              background: linear-gradient(160deg, #1d4ed8 0%, #2563eb 100%);
              color: #ffffff;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              font-weight: 800;
              font-size: 14px;
              letter-spacing: 0.08em;
              font-family: var(--mono);
            }

            .export-brand-text h1 { font-size: 24px; letter-spacing: -0.02em; }
            .export-brand-text p { margin-top: 4px; color: var(--muted); font-size: 13px; }

            .export-meta {
              display: flex;
              flex-wrap: wrap;
              gap: 8px;
              justify-content: flex-end;
              align-items: center;
            }

            .meta-pill {
              border: 1px solid var(--border);
              border-radius: 8px;
              padding: 6px 12px;
              background: var(--panel-soft);
              color: var(--text);
              font-size: 12px;
              line-height: 1.1;
              font-family: var(--mono);
            }

            .export-stats {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 10px;
            }

            .stat {
              background: var(--panel);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 16px;
              text-align: center;
              box-shadow: var(--shadow);
            }

            .stat-value {
              font-size: 26px;
              line-height: 1.1;
              font-weight: 800;
              color: var(--text);
              font-family: var(--mono);
            }

            .stat-label {
              margin-top: 6px;
              font-size: 11px;
              color: var(--muted);
              text-transform: uppercase;
              letter-spacing: 0.06em;
              font-weight: 600;
            }

            .stat--success .stat-value { color: var(--ok); }
            .stat--error .stat-value { color: var(--err); }
            .stat--info .stat-value { color: var(--info); }

            .export-query,
            .export-timeline,
            .export-usage {
              padding: 16px;
            }

            .export-query h3,
            .export-timeline h2,
            .export-usage h2 {
              font-size: 12px;
              text-transform: uppercase;
              letter-spacing: 0.08em;
              color: var(--muted);
              margin-bottom: 10px;
            }

            .step {
              background: var(--panel);
              border: 1px solid var(--border);
              border-radius: 12px;
              margin-bottom: 12px;
              overflow: hidden;
            }

            .step:last-child { margin-bottom: 0; }
            .step--error { border-left: 3px solid var(--err); }
            .step--final { border-left: 3px solid var(--info); }
            .step--user { border-left: 3px solid var(--user); }
            .step--ok { border-left: 3px solid var(--accent); }

            .step-header {
              display: flex;
              align-items: center;
              gap: 10px;
              padding: 12px 16px;
              background: var(--panel-soft);
              border-bottom: 1px solid var(--border);
            }

            .step-badge {
              font-size: 11px;
              font-weight: 700;
              color: var(--muted);
              padding: 4px 10px;
              border: 1px solid var(--border);
              border-radius: 6px;
              background: var(--badge-bg);
              font-family: var(--mono);
              letter-spacing: 0.04em;
              text-transform: uppercase;
            }

            .type-badge {
              font-size: 10px;
              font-weight: 700;
              text-transform: uppercase;
              letter-spacing: 0.05em;
              padding: 4px 10px;
              border-radius: 6px;
              border: 1px solid transparent;
              font-family: var(--mono);
            }

            .type-badge--exec {
              background: rgba(16, 185, 129, 0.15);
              color: var(--accent);
              border-color: rgba(16, 185, 129, 0.3);
            }

            .type-badge--final {
              background: rgba(59, 130, 246, 0.15);
              color: var(--info);
              border-color: rgba(59, 130, 246, 0.3);
            }
            
            .type-badge--user {
              background: rgba(168, 85, 247, 0.15);
              color: var(--user);
              border-color: rgba(168, 85, 247, 0.3);
            }

            .step-latency {
              margin-left: auto;
              font-size: 11px;
              color: var(--muted);
              font-family: var(--mono);
            }

            .step-body { padding: 16px; }
            .step-body h4 {
              font-size: 12px;
              text-transform: uppercase;
              letter-spacing: 0.07em;
              color: var(--muted);
              margin: 10px 0 8px;
            }

            .step-body h4:first-child { margin-top: 0; }

            .exec-out {
              background: var(--exec-bg);
              border: 1px solid var(--border);
              border-radius: 8px;
              padding: 12px;
              font-size: 12px;
              color: var(--exec-text);
            }

            .exec-out--error {
              border-color: var(--exec-err-border);
              background: var(--exec-err-bg);
            }

            .exec-out strong {
              display: block;
              margin-bottom: 6px;
              color: var(--err);
              font-size: 11px;
              text-transform: uppercase;
              letter-spacing: 0.06em;
            }

            .exec-out--error pre {
              background: var(--exec-err-pre);
              border-color: var(--exec-err-border);
              color: var(--exec-err-text);
            }

            .exec-stdout {
              color: var(--exec-stdout);
              font-family: var(--mono);
              white-space: pre-wrap;
            }

            .exec-value {
              margin-top: 8px;
              color: var(--exec-val);
              font-family: var(--mono);
            }

            .answer {
              padding: 16px 20px;
              background: var(--answer-bg);
              border: 1px solid var(--answer-border);
              border-radius: 12px;
            }
            
            .answer--user {
              background: var(--answer-usr-bg);
              border-color: var(--answer-usr-border);
            }

            .markdown-body {
              font-size: 13.5px;
              line-height: 1.6;
              color: var(--text);
            }
            .markdown-body > *:first-child { margin-top: 0; }
            .markdown-body > *:last-child { margin-bottom: 0; }
            .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4 {
              margin: 16px 0 8px; font-weight: 700; color: var(--text);
            }
            .markdown-body h1 { font-size: 18px; }
            .markdown-body h2 { font-size: 16px; }
            .markdown-body h3 { font-size: 14px; }
            .markdown-body p { margin-bottom: 12px; }
            .markdown-body ul, .markdown-body ol { margin: 8px 0 12px; padding-left: 20px; }
            .markdown-body li { margin-bottom: 4px; }
            .markdown-body code {
              background: rgba(168, 85, 247, 0.1); border-radius: 4px; padding: 2px 4px; font-size: 12px; color: #a855f7;
            }
            .markdown-body pre {
              background: var(--code-bg); border-color: var(--code-border); color: var(--code-text); padding: 12px; margin-bottom: 12px; border-radius: 8px; border: 1px solid var(--border);
            }
            .markdown-body pre code { background: none; color: inherit; padding: 0; }
            .markdown-body table { width: 100%; border-collapse: collapse; margin-bottom: 12px; }
            .markdown-body th, .markdown-body td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; }
            .markdown-body th { background: var(--panel-soft); font-weight: 600; font-size: 12px; color: var(--muted); }
            .markdown-body blockquote { border-left: 4px solid var(--info); padding-left: 12px; color: var(--muted); margin-bottom: 12px; }

            .usage-grid {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 10px;
            }

            .usage-item {
              background: var(--panel-soft);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 16px;
            }

            .usage-value {
              font-size: 20px;
              line-height: 1.2;
              font-weight: 700;
              font-family: var(--mono);
              color: var(--text);
            }

            .usage-label {
              margin-top: 4px;
              font-size: 10px;
              color: var(--muted);
              text-transform: uppercase;
              letter-spacing: 0.06em;
            }

            .export-footer {
              padding: 10px 14px;
              font-size: 11px;
              color: var(--muted);
              text-align: center;
            }

            @media (max-width: 900px) {
              body { padding: 16px; }
              .export-header { flex-direction: column; }
              .export-meta { justify-content: flex-start; }
              .export-stats, .usage-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
            }

            @media print {
              body {
                background: #ffffff;
                background-image: none;
                padding: 0;
              }

              .export-header,
              .export-query,
              .export-timeline,
              .export-usage,
              .export-footer,
              .stat {
                box-shadow: none;
              }

              .step { page-break-inside: avoid; }
            }
          CSS
        end
      end
    end
  end
end
