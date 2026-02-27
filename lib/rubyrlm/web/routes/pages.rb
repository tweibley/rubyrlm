module RubyRLM
  module Web
    module Routes
      module Pages
        def self.registered(app)
          boot_version = Time.now.to_i.to_s

          app.get "/" do
            content_type "text/html"
            Pages.spa_shell(boot_version)
          end
        end

        def self.spa_shell(version = '1')
          <<~HTML
<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>RubyRLM Industrial Console</title>

  <!-- Fonts -->
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;900&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">

  <!-- Icons -->
  <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">

  <!-- Syntax Highlighting -->
  <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/prism.min.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-ruby.min.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/plugins/line-numbers/prism-line-numbers.min.js"></script>
  <link href="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/plugins/line-numbers/prism-line-numbers.min.css" rel="stylesheet">

  <!-- Diagrams -->
  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>

  <!-- Markdown -->
  <script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>

  <!-- Charts -->
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>

  <link rel="stylesheet" href="/css/design-system.css?v=#{version}">
  <link rel="stylesheet" href="/css/components.css?v=#{version}">
</head>
<body>
  <div class="grid-overlay"></div>

  <nav class="top-nav">
    <div class="top-nav__brand">
      <div class="top-nav__logo"><i class="fa-solid fa-terminal"></i></div>
      <div class="top-nav__title-group">
        <h1 class="top-nav__title">RubyRLM</h1>
        <div class="top-nav__subtitle">INDUSTRIAL SESSION CONSOLE</div>
      </div>
    </div>

    <div class="top-nav__modes">
      <button class="mode-btn mode-btn--active" data-mode="sessions" onclick="switchMode('sessions')">
        <i class="fa-solid fa-diagram-project"></i> Sessions
      </button>
      <button class="mode-btn" data-mode="analytics" onclick="switchMode('analytics')">
        <i class="fa-solid fa-chart-column"></i> Analytics
      </button>
      <button class="mode-btn" data-mode="query" onclick="switchMode('query')">
        <i class="fa-solid fa-terminal"></i> Controller
      </button>
    </div>

    <div class="top-nav__telemetry">
      <span class="telemetry-pill"><i class="fa-solid fa-circle"></i> NODE ONLINE</span>
      <span class="telemetry-pill telemetry-pill--muted">BUILD: SYS/03</span>
    </div>

    <div class="top-nav__actions">
      <button class="theme-toggle" onclick="toggleTheme()" title="Toggle theme">
        <i class="fa-solid fa-moon" id="theme-icon"></i>
      </button>
    </div>
  </nav>

  <div class="app-layout">
    <aside class="sidebar" id="sidebar">
      <div class="sidebar__section" data-sidebar="sessions">
        <div class="sidebar__header sidebar__header--with-actions">
          <span>Session Index</span>
          <div class="sidebar__header-actions">
            <button class="sidebar__header-btn" onclick="SessionList.clearSelection()">Clear</button>
            <button class="sidebar__header-btn sidebar__header-btn--accent" onclick="startNewSessionFlow()">New</button>
          </div>
        </div>
        <div id="session-list" class="sidebar__list">
          <div class="sidebar__loading">Loading sessions...</div>
        </div>
      </div>

      <div class="sidebar__section sidebar__section--hidden" data-sidebar="analytics">
        <div class="sidebar__header">Analytics Channels</div>
        <div class="sidebar__nav-list">
          <a href="#" class="sidebar__nav-item sidebar__nav-item--active" onclick="scrollToSection('kpi-section')">
            <i class="fa-solid fa-gauge-high"></i> KPI Overview
          </a>
          <a href="#" class="sidebar__nav-item" onclick="scrollToSection('token-charts')">
            <i class="fa-solid fa-coins"></i> Token Throughput
          </a>
          <a href="#" class="sidebar__nav-item" onclick="scrollToSection('model-breakdown')">
            <i class="fa-solid fa-robot"></i> Model Mix
          </a>
          <a href="#" class="sidebar__nav-item" onclick="scrollToSection('error-analysis')">
            <i class="fa-solid fa-bug"></i> Fault Classes
          </a>
          <a href="#" class="sidebar__nav-item" onclick="scrollToSection('comparison-section')">
            <i class="fa-solid fa-code-compare"></i> Session Compare
          </a>
        </div>
      </div>

      <div class="sidebar__section sidebar__section--hidden" data-sidebar="query">
        <div class="sidebar__header">Engine Config</div>
        <div class="sidebar__form">
          <label class="form-label">Model</label>
          <select id="query-model" class="form-select">
            <option value="gemini-3.1-pro-preview">gemini-3.1-pro-preview</option>
          </select>
          <label class="form-label">Thinking Level</label>
          <select id="query-thinking" class="form-select">
            <option value="low">Low</option>
            <option value="medium" selected>Medium</option>
            <option value="high">High</option>
          </select>
          <label class="form-label">Execution Environment</label>
          <select id="query-environment" class="form-select">
            <option value="local">Local (Host Process)</option>
            <option value="docker" selected>Docker Isolated Container</option>
          </select>
          <label class="form-label form-label--inline">
            <input type="checkbox" id="query-docker-network" checked>
            Allow Docker Network Access
          </label>
          <label class="form-label form-label--inline">
            <input type="checkbox" id="query-docker-keep-alive">
            Keep Container Alive
          </label>
          <label class="form-label">Reuse Container Instance</label>
          <select id="query-docker-reuse-id" class="form-select">
            <option value="">-- New Container --</option>
          </select>
          <div class="form-help">
            Docker mode uses strict isolation and reads Gemini credentials from a container secret file.
          </div>
          <label class="form-label">Max Iterations</label>
          <input type="number" id="query-max-iter" class="form-input" value="30" min="1" max="100">
          <label class="form-label">Execution Timeout (s)</label>
          <input type="number" id="query-timeout" class="form-input" value="60" min="5" max="300">
          <label class="form-label">Max Depth</label>
          <input type="number" id="query-max-depth" class="form-input" value="1" min="0" max="5">
          <label class="form-label">Temperature</label>
          <input type="number" id="query-temp" class="form-input" value="0.5" min="0" max="2" step="0.1">
        </div>
      </div>
    </aside>

    <main class="main-content" id="main-content">
      <div class="main-view" data-view="sessions" id="sessions-view">
        <div class="main-view__empty" id="sessions-empty">
          <i class="fa-solid fa-box-archive"></i>
          <p>Select a session to inspect execution traces.</p>
        </div>

        <div class="session-header node node--hero" id="session-header" style="display:none">
          <h2 class="session-header__title" id="header-title">Session</h2>
          <div class="session-header__meta">
            <span class="meta-item"><i class="fa-regular fa-calendar"></i> <span id="header-date">...</span></span>
            <span class="meta-sep"></span>
            <span class="meta-item meta-item--accent"><i class="fa-solid fa-file-code"></i> <span id="header-file">...</span></span>
            <span class="meta-sep"></span>
            <span class="meta-badge" id="header-model">...</span>
            <span class="meta-sep"></span>
            <span class="meta-item"><span id="header-steps-count">0</span> steps</span>
            <span class="meta-item meta-item--ok"><i class="fa-solid fa-check-circle"></i> <span id="header-ok-count">0</span></span>
            <span class="meta-item meta-item--err"><i class="fa-solid fa-times-circle"></i> <span id="header-err-count">0</span></span>
          </div>
          <div class="session-header__query">
            <div class="section-label"><i class="fa-solid fa-terminal"></i> Query Input</div>
            <div class="query-text" id="header-query">No query recorded.</div>
          </div>
        </div>

        <div class="flow-view" id="flow-view" style="display:none">
          <div class="node node--elevated">
            <div class="section-label"><i class="fa-solid fa-diagram-project"></i> Execution Graph</div>
            <div class="mermaid-container" id="exec-chain-diagram"></div>
          </div>
          <div class="node" id="recursion-tree-container" style="display:none">
            <div class="section-label"><i class="fa-solid fa-sitemap"></i> Recursion Tree</div>
            <div class="mermaid-container" id="recursion-tree-diagram"></div>
          </div>
        </div>

        <div id="timeline" class="timeline"></div>

        <div class="node" id="usage-summary" style="display:none">
          <div class="section-label"><i class="fa-solid fa-chart-bar"></i> Run Summary</div>
          <div class="summary-grid">
            <div class="summary-card">
              <div class="summary-card__label">Total Time</div>
              <div class="summary-card__value" id="summary-time">0.00s</div>
            </div>
            <div class="summary-card">
              <div class="summary-card__label">LLM Calls</div>
              <div class="summary-card__value" id="summary-calls">0</div>
            </div>
            <div class="summary-card">
              <div class="summary-card__label">Prompt Tokens</div>
              <div class="summary-card__value" id="summary-pt">0</div>
            </div>
            <div class="summary-card">
              <div class="summary-card__label">Candidate Tokens</div>
              <div class="summary-card__value" id="summary-ct">0</div>
            </div>
          </div>
        </div>
      </div>

      <div class="main-view main-view--hidden" data-view="analytics" id="analytics-view">
        <div class="kpi-header" style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 2rem;">
          <h2 style="margin: 0; color: var(--color-primary); font-family: 'JetBrains Mono', monospace; font-size: 1.25rem;">Analytics Overview</h2>
          <select id="kpi-time-filter" class="form-select" style="width: auto; margin: 0;">
            <option value="0" selected>All Time</option>
            <option value="1">Last 24 Hours</option>
            <option value="7">Last 7 Days</option>
            <option value="30">Last 30 Days</option>
          </select>
        </div>
        <div id="kpi-section" class="kpi-grid"></div>
        <div class="analytics-charts">
          <div class="node node--elevated" id="token-charts">
            <div class="section-label"><i class="fa-solid fa-coins"></i> Token Usage Over Time</div>
            <div class="chart-container"><canvas id="token-chart"></canvas></div>
          </div>
          <div class="node" id="model-breakdown">
            <div class="section-label"><i class="fa-solid fa-robot"></i> Model Distribution</div>
            <div class="chart-container chart-container--small"><canvas id="model-chart"></canvas></div>
          </div>
          <div class="node" id="error-analysis">
            <div class="section-label"><i class="fa-solid fa-bug"></i> Top Errors</div>
            <div class="chart-container"><canvas id="error-chart"></canvas></div>
          </div>
        </div>
        <div class="node" id="comparison-section">
          <div class="section-label"><i class="fa-solid fa-code-compare"></i> Session Comparison</div>
          <div class="comparison-controls">
            <select id="compare-a" class="form-select"><option value="">Select session A</option></select>
            <span class="comparison-vs">vs</span>
            <select id="compare-b" class="form-select"><option value="">Select session B</option></select>
            <button class="btn btn--accent" onclick="compareSelectedSessions()">Compare</button>
          </div>
          <div id="comparison-result"></div>
        </div>
      </div>

      <div class="main-view main-view--hidden" data-view="query" id="query-view">
        <div class="node node--hero">
          <div class="query-header">
            <div class="section-label"><i class="fa-solid fa-terminal"></i> System Controller Prompt</div>
            <div class="query-warning" id="query-warning-banner">
              <i class="fa-solid fa-shield-halved"></i>
              Prompts execute arbitrary Ruby code locally. Run only trusted instructions.
            </div>
          </div>
          <textarea id="query-prompt" class="query-textarea" placeholder=">_ Enter command..." rows="5"></textarea>
          <div class="query-actions">
            <button class="btn btn--accent" id="query-run-btn" onclick="submitQuery()">
              <i class="fa-solid fa-play"></i> Execute
            </button>
            <button class="btn btn--danger" id="query-cancel-btn" onclick="cancelQuery()" style="display:none">
              <i class="fa-solid fa-stop"></i> Cancel
            </button>
          </div>
        </div>
        <div id="query-timeline" class="timeline"></div>
      </div>
    </main>

    <aside class="steps-panel steps-panel--hidden" id="steps-sidebar">
      <div class="steps-panel__stats">
        <div class="steps-panel__thread-title">
          <i class="fa-solid fa-diagram-project"></i>
          <span>Process Thread</span>
        </div>
        <div class="stat-grid">
          <div class="stat-card">
            <span class="stat-card__value" id="stat-total">0</span>
            <span class="stat-card__label">Steps</span>
          </div>
          <div class="stat-card stat-card--success">
            <span class="stat-card__value" id="stat-success">0</span>
            <span class="stat-card__label">OK</span>
          </div>
          <div class="stat-card stat-card--error">
            <span class="stat-card__value" id="stat-error">0</span>
            <span class="stat-card__label">Errors</span>
          </div>
          <div class="stat-card stat-card--info">
            <span class="stat-card__value" id="stat-submits">0</span>
            <span class="stat-card__label">Final</span>
          </div>
        </div>
        <div class="progress-bar" id="stat-progress"></div>
        <div class="sparkline-container" id="latency-sparkline-wrap" style="display:none">
          <canvas id="latency-sparkline" height="40"></canvas>
        </div>
      </div>
      <div class="steps-panel__header">
        <span>Step Navigator</span>
        <div class="view-toggle">
          <button class="view-toggle__btn view-toggle__btn--active" data-view="timeline" onclick="setView('timeline')">
            <i class="fa-solid fa-bars-staggered"></i>
          </button>
          <button class="view-toggle__btn" data-view="flow" onclick="setView('flow')">
            <i class="fa-solid fa-share-nodes"></i>
          </button>
        </div>
      </div>
      <div id="step-list" class="steps-panel__list"></div>
    </aside>
  </div>

  <footer class="status-bar">
    <div class="status-bar__left">
      <span><i class="fa-solid fa-circle"></i> SYSTEM: NOMINAL</span>
      <span>ID: RL-SYS-01-A</span>
    </div>
    <div class="status-bar__right">
      <span>RUBYRLM INDUSTRIAL INTERFACE</span>
    </div>
  </footer>

  <script src="/js/utils.js?v=#{version}"></script>
  <script src="/js/lib/theme-manager.js?v=#{version}"></script>
  <script src="/js/lib/diagram-renderer.js?v=#{version}"></script>
  <script src="/js/lib/chart-renderer.js?v=#{version}"></script>
  <script src="/js/lib/animation.js?v=#{version}"></script>
  <script src="/js/lib/sse-client.js?v=#{version}"></script>
  <script src="/js/components/session-list.js?v=#{version}"></script>
  <script src="/js/components/step-navigator.js?v=#{version}"></script>
  <script src="/js/components/timeline.js?v=#{version}"></script>
  <script src="/js/components/exec-chain.js?v=#{version}"></script>
  <script src="/js/components/recursion-tree.js?v=#{version}"></script>
  <script src="/js/components/charts.js?v=#{version}"></script>
  <script src="/js/components/kpi-dashboard.js?v=#{version}"></script>
  <script src="/js/components/query-panel.js?v=#{version}"></script>
  <script src="/js/components/context-inspector.js?v=#{version}"></script>
  <script src="/js/app.js?v=#{version}"></script>
</body>
</html>
          HTML
        end
      end
    end
  end
end
