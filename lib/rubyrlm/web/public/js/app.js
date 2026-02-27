// Main application controller

const App = {
  currentMode: 'sessions',
  currentView: 'timeline',
  currentSession: null,

  init() {
    SessionList.load();

    // Restore session from URL hash on page load
    const hash = window.location.hash.replace('#', '');
    if (hash) {
      this._pendingSessionId = hash;
    }

    // Listen for back/forward navigation
    window.addEventListener('popstate', () => {
      const id = window.location.hash.replace('#', '');
      if (id && (!this.currentSession || this.currentSession.run_start?.run_id !== id)) {
        this.loadSessionById(id);
      }
    });
  },

  showStreamingSession(runId, prompt, model) {
    document.getElementById('sessions-empty').style.display = 'none';
    document.getElementById('session-header').style.display = 'block';

    document.getElementById('header-title').textContent = 'Run: ' + (runId ? shortId(runId) : '...');
    document.getElementById('header-date').textContent = formatDate(new Date().toISOString());
    document.getElementById('header-file').textContent = '';
    document.getElementById('header-model').textContent = model || 'gemini-3.1-pro-preview';
    document.getElementById('header-query').textContent = prompt || 'No query recorded.';

    document.getElementById('header-steps-count').textContent = '0';
    document.getElementById('header-ok-count').textContent = '0';
    document.getElementById('header-err-count').textContent = '0';

    const b1 = document.getElementById('header-continuation-badge');
    const b2 = document.getElementById('header-continuation-link');
    if (b1) b1.style.display = 'none';
    if (b2) b2.style.display = 'none';

    // Ensure the timeline is visible and flow-view is hidden
    document.getElementById('timeline').style.display = 'flex';
    document.getElementById('flow-view').style.display = 'none';

    this.ensureActionButtons(runId);

    if (typeof switchMode === 'function') {
      switchMode('sessions');
    }
  },

  renderSessionHeader(rs, session) {
    document.getElementById('sessions-empty').style.display = 'none';
    document.getElementById('session-header').style.display = 'block';

    document.getElementById('header-title').textContent = rs ? 'Run: ' + shortId(rs.run_id) : 'Session';
    document.getElementById('header-date').textContent = rs ? formatDate(rs.timestamp) : 'Unknown';
    document.getElementById('header-file').textContent = session.filename || '';
    document.getElementById('header-model').textContent = rs ? rs.model : 'unknown';
    this.renderContinuationBadge(session);
    document.getElementById('header-query').textContent = rs && rs.prompt ? rs.prompt : 'No query recorded.';

    const stats = session.stats || {};
    document.getElementById('header-steps-count').textContent = stats.total || 0;
    document.getElementById('header-ok-count').textContent = stats.success || 0;
    document.getElementById('header-err-count').textContent = stats.errors || 0;

    this.ensureActionButtons(rs?.run_id);
  },

  ensureActionButtons(runId) {
    let actionBar = document.getElementById('session-action-bar');
    if (!actionBar) {
      actionBar = document.createElement('div');
      actionBar.id = 'session-action-bar';
      actionBar.className = 'session-header__actions';
      const meta = document.getElementById('session-header').querySelector('.session-header__meta');
      if (meta) meta.after(actionBar);
    }
  },

  async loadSessionById(id) {
    try {
      const session = await fetchJSON('/api/sessions/' + id);
      if (session) this.showSession(session, { pushState: false });
    } catch (e) { console.error('Failed to load session:', e); }
  },

  showSession(session, opts = {}) {
    this.currentSession = session;
    const pushState = opts.pushState !== false;

    // Update URL bar so the user can reload and return to this session
    const runId = session.run_start?.run_id;
    if (typeof SessionList !== 'undefined') {
      SessionList.activeId = runId || null;
      document.querySelectorAll('.session-item').forEach(btn => {
        btn.classList.toggle('session-item--active', btn.dataset.id === SessionList.activeId);
      });
    }
    if (runId && pushState) {
      history.pushState(null, '', '#' + runId);
    }

    this.renderSessionHeader(session.run_start, session);

    // Add action buttons container
    // Delegation moved to ensureActionButtons
    let actionBar = document.getElementById('session-action-bar');

    // Export HTML button
    let exportBtn = document.getElementById('export-btn');
    if (!exportBtn) {
      exportBtn = document.createElement('button');
      exportBtn.id = 'export-btn';
      exportBtn.className = 'btn';
      const icon = document.createElement('i');
      icon.className = 'fa-solid fa-download';
      exportBtn.appendChild(icon);
      exportBtn.appendChild(document.createTextNode(' Export HTML'));
      actionBar.appendChild(exportBtn);
    }
    exportBtn.onclick = async () => {
      const runId = session.run_start?.run_id;
      if (!runId) return;
      try {
        const theme = document.documentElement.getAttribute('data-theme') || 'light';
        const res = await fetch('/api/sessions/' + runId + '/export?theme=' + theme, { method: 'POST' });
        if (res.ok) {
          const blob = await res.blob();
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          a.download = 'rubyrlm-session-' + runId.substring(0, 8) + '.html';
          a.click();
          URL.revokeObjectURL(url);
        }
      } catch (err) { console.error('Export failed:', err); }
    };

    const pngName = runId ? ('rubyrlm-' + runId.substring(0, 8) + '.png') : 'rubyrlm-session.png';

    const fetchSessionPng = async () => {
      if (!runId) return null;
      const theme = document.documentElement.getAttribute('data-theme') || 'light';
      const res = await fetch('/api/sessions/' + runId + '/share.png?theme=' + theme);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.blob();
    };

    let downloadPngBtn = document.getElementById('download-png-btn');
    if (!downloadPngBtn) {
      downloadPngBtn = document.createElement('button');
      downloadPngBtn.id = 'download-png-btn';
      downloadPngBtn.className = 'btn';
      const downloadIcon = document.createElement('i');
      downloadIcon.className = 'fa-solid fa-file-arrow-down';
      downloadPngBtn.appendChild(downloadIcon);
      downloadPngBtn.appendChild(document.createTextNode(' Download PNG'));
      actionBar.appendChild(downloadPngBtn);
    }
    downloadPngBtn.onclick = async () => {
      if (!runId) return;
      downloadPngBtn.disabled = true;
      const origText = downloadPngBtn.lastChild.textContent;
      downloadPngBtn.lastChild.textContent = ' Generating...';
      try {
        const blob = await fetchSessionPng();
        if (blob) this.downloadBlob(blob, pngName);
      } catch (err) {
        console.error('Download PNG failed:', err);
      }
      downloadPngBtn.lastChild.textContent = origText;
      downloadPngBtn.disabled = false;
    };

    // Share PNG button (native share where available)
    let shareBtn = document.getElementById('share-btn');
    if (!shareBtn) {
      shareBtn = document.createElement('button');
      shareBtn.id = 'share-btn';
      shareBtn.className = 'btn btn--accent';
      const shareIcon = document.createElement('i');
      shareIcon.className = 'fa-solid fa-share-from-square';
      shareBtn.appendChild(shareIcon);
      shareBtn.appendChild(document.createTextNode(' Share Image'));
      actionBar.appendChild(shareBtn);
    }
    shareBtn.onclick = async () => {
      if (!runId) return;
      shareBtn.disabled = true;
      const origText = shareBtn.lastChild.textContent;
      shareBtn.lastChild.textContent = ' Sharing...';
      try {
        const blob = await fetchSessionPng();
        if (!blob) return;

        if (navigator.share && navigator.canShare) {
          const file = new File([blob], pngName, { type: 'image/png' });
          if (navigator.canShare({ files: [file] })) {
            await navigator.share({ files: [file], title: 'RubyRLM Session' });
          } else {
            this.downloadBlob(blob, pngName);
          }
        } else {
          this.downloadBlob(blob, pngName);
        }
      } catch (err) {
        console.error('Share failed:', err);
      }
      shareBtn.lastChild.textContent = origText;
      shareBtn.disabled = false;
    };

    // Delete session button
    let deleteBtn = document.getElementById('delete-session-btn');
    if (!deleteBtn) {
      deleteBtn = document.createElement('button');
      deleteBtn.id = 'delete-session-btn';
      deleteBtn.className = 'btn btn--danger';
      const deleteIcon = document.createElement('i');
      deleteIcon.className = 'fa-solid fa-trash';
      deleteBtn.appendChild(deleteIcon);
      deleteBtn.appendChild(document.createTextNode(' Delete Session'));
      actionBar.appendChild(deleteBtn);
    }
    deleteBtn.onclick = async () => {
      if (!runId) return;
      const ok = window.confirm('Delete session ' + shortId(runId) + '? This cannot be undone.');
      if (!ok) return;

      deleteBtn.disabled = true;
      const origText = deleteBtn.lastChild.textContent;
      deleteBtn.lastChild.textContent = ' Deleting...';
      try {
        const res = await fetch('/api/sessions/' + runId, { method: 'DELETE' });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        SessionList.activeId = null;
        await SessionList.load({ preserveSelection: false });
      } catch (err) {
        console.error('Delete session failed:', err);
      }
      deleteBtn.lastChild.textContent = origText;
      deleteBtn.disabled = false;
    };

    // Update step navigator
    StepNavigator.update(session);

    // Render the active view
    this.renderCurrentView(session);

    // Usage summary
    this.renderUsageSummary(session);
  },

  renderCurrentView(session) {
    if (!session) return;

    if (this.currentView === 'timeline') {
      document.getElementById('flow-view').style.display = 'none';
      document.getElementById('timeline').style.display = 'flex';
      Timeline.render(session);
      // Add inline continue prompt at the bottom of the timeline
      ContinuePrompt.render(session, document.getElementById('timeline'));
    } else {
      document.getElementById('timeline').style.display = 'none';
      document.getElementById('flow-view').style.display = 'block';
      ExecChain.render(session);
      if (session.run_start) {
        RecursionTree.render(session.run_start.run_id);
      }
    }
  },

  renderUsageSummary(session) {
    const re = session.run_end;
    const summaryDiv = document.getElementById('usage-summary');

    if (re && re.usage) {
      summaryDiv.style.display = 'block';
      document.getElementById('summary-time').textContent = (re.execution_time || 0).toFixed(2) + 's';
      document.getElementById('summary-calls').textContent = re.usage.calls || 0;
      document.getElementById('summary-pt').textContent = formatNumber(re.usage.prompt_tokens || 0);
      document.getElementById('summary-ct').textContent = formatNumber(re.usage.candidate_tokens || 0);
    } else {
      summaryDiv.style.display = 'none';
    }

    // Render per-iteration token usage chart
    Charts.renderSessionCharts(session);
  },

  renderContinuationBadge(session) {
    const metaEl = document.getElementById('session-header')?.querySelector('.session-header__meta');
    if (!metaEl) return;

    let badge = document.getElementById('header-continuation-badge');
    if (!badge) {
      badge = document.createElement('span');
      badge.id = 'header-continuation-badge';
      badge.className = 'meta-badge';
      metaEl.appendChild(badge);
    }

    const mode = session.latest_run_start?.continuation_mode || 'new';
    if (mode === 'append') {
      badge.textContent = 'CONTINUED';
      badge.style.display = 'inline-flex';
      badge.title = 'Latest run appended to this session';
    } else if (mode === 'fork') {
      badge.textContent = 'FORKED';
      badge.style.display = 'inline-flex';
      badge.title = 'Latest run was created by forking another session';
    } else {
      badge.textContent = '';
      badge.style.display = 'none';
      badge.title = '';
    }
  },

  clearSessionView() {
    this.currentSession = null;

    if (window.location.hash) {
      history.pushState(null, '', window.location.pathname);
    }

    const empty = document.getElementById('sessions-empty');
    if (empty) empty.style.display = 'flex';

    const header = document.getElementById('session-header');
    if (header) header.style.display = 'none';

    const timeline = document.getElementById('timeline');
    if (timeline) {
      timeline.textContent = '';
      timeline.style.display = 'none';
    }

    const flow = document.getElementById('flow-view');
    if (flow) flow.style.display = 'none';

    const usage = document.getElementById('usage-summary');
    if (usage) usage.style.display = 'none';

    StepNavigator.hide();
  },

  downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }
};

// --- Global UI functions called from HTML ---

function switchMode(mode) {
  App.currentMode = mode;

  // Update mode buttons
  document.querySelectorAll('.mode-btn').forEach(btn => {
    btn.classList.toggle('mode-btn--active', btn.dataset.mode === mode);
  });

  // Show/hide sidebars
  document.querySelectorAll('[data-sidebar]').forEach(section => {
    section.classList.toggle('sidebar__section--hidden', section.dataset.sidebar !== mode);
  });

  // Show/hide main views
  document.querySelectorAll('[data-view]').forEach(view => {
    view.classList.toggle('main-view--hidden', view.dataset.view !== mode);
  });

  // Show/hide steps panel
  if (mode === 'sessions' && App.currentSession) {
    document.getElementById('steps-sidebar').classList.remove('steps-panel--hidden');
  } else {
    document.getElementById('steps-sidebar').classList.add('steps-panel--hidden');
  }

  // Load analytics data when switching to analytics mode
  if (mode === 'analytics') {
    KPIDashboard.load();
  }
}

function setView(view) {
  App.currentView = view;

  document.querySelectorAll('.view-toggle__btn').forEach(btn => {
    btn.classList.toggle('view-toggle__btn--active', btn.dataset.view === view);
  });

  if (App.currentSession) {
    App.renderCurrentView(App.currentSession);
  }
}

function startNewSessionFlow() {
  if (typeof SessionList !== 'undefined' && SessionList.clearSelection) {
    SessionList.clearSelection();
  } else {
    App.clearSessionView();
  }
  App._pendingSessionId = null;

  // Reset Controller continuation state
  if (typeof QueryPanel !== 'undefined') {
    QueryPanel.lastSessionId = null;
  }

  const queryTimeline = document.getElementById('query-timeline');
  if (queryTimeline) queryTimeline.textContent = '';
  const queryResult = document.getElementById('query-result');
  if (queryResult) queryResult.style.display = 'none';
  const queryAnswer = document.getElementById('query-answer');
  if (queryAnswer) queryAnswer.textContent = '';

  if (typeof QueryPanel !== 'undefined' && QueryPanel.clearRetryNotice) {
    QueryPanel.clearRetryNotice();
  }

  switchMode('query');
  const textarea = document.getElementById('query-prompt');
  if (textarea) {
    textarea.value = '';
    textarea.placeholder = '>_ Enter command...';
    textarea.focus();
  }
}

function scrollToSection(id) {
  const el = document.getElementById(id);
  if (el) el.scrollIntoView({ behavior: 'smooth' });
}

async function compareSelectedSessions() {
  const idA = document.getElementById('compare-a').value;
  const idB = document.getElementById('compare-b').value;
  if (!idA || !idB) return;

  const resultDiv = document.getElementById('comparison-result');
  resultDiv.textContent = 'Loading...';

  try {
    const data = await fetchJSON('/api/sessions/' + idA + '/compare/' + idB);
    renderComparison(data, resultDiv);
  } catch (err) {
    resultDiv.textContent = 'Comparison failed: ' + err.message;
  }
}

function renderComparison(data, container) {
  container.textContent = '';

  const sA = data.session_a;
  const sB = data.session_b;
  const table = buildComparisonSummaryTable(sA, sB);
  container.appendChild(table);

  const split = buildComparisonSplitView(sA, sB);
  container.appendChild(split.wrapper);
  attachSyncedScroll(split.leftTimeline, split.rightTimeline);
}

function buildComparisonSummaryTable(sA, sB) {
  const table = document.createElement('table');
  table.className = 'comparison-table comparison-table--summary';

  const thead = document.createElement('thead');
  const headerRow = document.createElement('tr');
  ['Metric', 'Session A', 'Session B'].forEach(text => {
    const th = document.createElement('th');
    th.textContent = text;
    headerRow.appendChild(th);
  });
  thead.appendChild(headerRow);
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  const formatExecTime = (session) => {
    const seconds = session?.run_end?.execution_time;
    return Number.isFinite(seconds) ? seconds.toFixed(2) + 's' : '-';
  };

  const rows = [
    ['Steps', sA.stats?.total, sB.stats?.total],
    ['Successes', sA.stats?.success, sB.stats?.success],
    ['Errors', sA.stats?.errors, sB.stats?.errors],
    ['Model', sA.run_start?.model, sB.run_start?.model],
    ['Total Time', formatExecTime(sA), formatExecTime(sB)],
    ['Tokens', formatNumber(sA.run_end?.usage?.total_tokens), formatNumber(sB.run_end?.usage?.total_tokens)],
    ['Prompt Tokens', formatNumber(sA.run_end?.usage?.prompt_tokens), formatNumber(sB.run_end?.usage?.prompt_tokens)],
    ['Candidate Tokens', formatNumber(sA.run_end?.usage?.candidate_tokens), formatNumber(sB.run_end?.usage?.candidate_tokens)]
  ];

  rows.forEach(([label, valA, valB]) => {
    const tr = document.createElement('tr');
    [label, valA ?? '-', valB ?? '-'].forEach(text => {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });

  table.appendChild(tbody);
  return table;
}

function buildComparisonSplitView(sA, sB) {
  const wrapper = document.createElement('div');
  wrapper.className = 'comparison-split';

  const leftPane = buildComparisonPane('Session A', sA);
  const rightPane = buildComparisonPane('Session B', sB);

  wrapper.appendChild(leftPane.pane);
  wrapper.appendChild(rightPane.pane);

  return {
    wrapper,
    leftTimeline: leftPane.timeline,
    rightTimeline: rightPane.timeline
  };
}

function buildComparisonPane(label, session) {
  const pane = document.createElement('section');
  pane.className = 'comparison-pane node node--recessed';

  const header = document.createElement('header');
  header.className = 'comparison-pane__header';

  const title = document.createElement('div');
  title.className = 'comparison-pane__title';
  title.textContent = label;
  header.appendChild(title);

  const runMeta = document.createElement('div');
  runMeta.className = 'comparison-pane__meta';
  const runId = session?.run_start?.run_id;
  const model = session?.run_start?.model || 'unknown';
  runMeta.textContent = (runId ? shortId(runId) : 'No run id') + ' | ' + model;
  header.appendChild(runMeta);

  pane.appendChild(header);

  const timeline = document.createElement('div');
  timeline.className = 'comparison-pane__timeline';

  const iterations = session?.iterations || [];
  if (!iterations.length) {
    const empty = document.createElement('div');
    empty.className = 'comparison-pane__empty';
    empty.textContent = 'No iterations recorded.';
    timeline.appendChild(empty);
  } else {
    iterations.forEach((it) => {
      const d = it.data || it;
      timeline.appendChild(buildComparisonStep(d));
    });
  }

  pane.appendChild(timeline);
  return { pane, timeline };
}

function buildComparisonStep(step) {
  const card = document.createElement('article');
  const isSubmit = step.action === 'final' || step.action === 'forced_final';
  const isError = !isSubmit && step.execution && !step.execution.ok;
  card.className = 'comparison-step';
  if (isSubmit) card.classList.add('comparison-step--final');
  if (isError) card.classList.add('comparison-step--error');

  const header = document.createElement('div');
  header.className = 'comparison-step__header';
  header.textContent = `Step ${step.iteration || '?'} | ${String(step.action || 'exec').toUpperCase()}`;
  card.appendChild(header);

  const body = document.createElement('div');
  body.className = 'comparison-step__body';

  if (!isSubmit) {
    const codeLabel = document.createElement('div');
    codeLabel.className = 'comparison-step__label';
    codeLabel.textContent = 'Code';
    body.appendChild(codeLabel);

    const codeBlock = document.createElement('pre');
    codeBlock.className = 'comparison-step__content';
    codeBlock.textContent = truncate(step.code || '', 450);
    body.appendChild(codeBlock);

    const outputLabel = document.createElement('div');
    outputLabel.className = 'comparison-step__label';
    outputLabel.textContent = 'Result';
    body.appendChild(outputLabel);

    const outputBlock = document.createElement('pre');
    outputBlock.className = 'comparison-step__content';
    outputBlock.textContent = summarizeComparisonExecution(step.execution);
    body.appendChild(outputBlock);
  } else {
    const finalLabel = document.createElement('div');
    finalLabel.className = 'comparison-step__label';
    finalLabel.textContent = 'Final Answer';
    body.appendChild(finalLabel);

    const finalBlock = document.createElement('pre');
    finalBlock.className = 'comparison-step__content';
    finalBlock.textContent = truncate(step.answer || '', 600);
    body.appendChild(finalBlock);
  }

  card.appendChild(body);
  return card;
}

function summarizeComparisonExecution(execution) {
  if (!execution) return '(no execution details)';
  if (!execution.ok) {
    const type = execution.error_class || 'Error';
    const msg = execution.error_message || '';
    return `${type}: ${msg}`.trim();
  }

  if (execution.stdout) return truncate(execution.stdout, 400);
  if (execution.value_preview) return truncate(String(execution.value_preview), 400);
  return '(ok)';
}

function attachSyncedScroll(leftEl, rightEl) {
  if (!leftEl || !rightEl) return;

  let syncing = false;
  const syncTo = (source, target) => {
    if (syncing) return;
    const sourceRange = Math.max(1, source.scrollHeight - source.clientHeight);
    const targetRange = Math.max(0, target.scrollHeight - target.clientHeight);
    const ratio = source.scrollTop / sourceRange;

    syncing = true;
    target.scrollTop = ratio * targetRange;
    requestAnimationFrame(() => { syncing = false; });
  };

  leftEl.addEventListener('scroll', () => syncTo(leftEl, rightEl));
  rightEl.addEventListener('scroll', () => syncTo(rightEl, leftEl));
}

// --- Inline continue prompt at the bottom of a session ---

const ContinuePrompt = {
  activeSSE: null,
  activeRunId: null,
  streamingCard: null,
  retryNoticeEl: null,
  _container: null,

  render(session, container) {
    this._container = container;
    // Remove any existing continue prompt
    const existing = document.getElementById('continue-prompt-box');
    if (existing) existing.remove();

    const box = document.createElement('div');
    box.id = 'continue-prompt-box';
    box.className = 'node continue-prompt';

    const label = document.createElement('div');
    label.className = 'section-label';
    const labelIcon = document.createElement('i');
    labelIcon.className = 'fa-solid fa-forward';
    label.appendChild(labelIcon);
    label.appendChild(document.createTextNode(' Continue Session'));
    box.appendChild(label);

    const textarea = document.createElement('textarea');
    textarea.id = 'continue-textarea';
    textarea.className = 'query-textarea';
    textarea.placeholder = 'Ask a follow-up question...';
    textarea.rows = 2;
    box.appendChild(textarea);

    const actions = document.createElement('div');
    actions.className = 'continue-prompt__actions';

    const runBtn = document.createElement('button');
    runBtn.id = 'continue-run-btn';
    runBtn.className = 'btn btn--accent';
    const runIcon = document.createElement('i');
    runIcon.className = 'fa-solid fa-play';
    runBtn.appendChild(runIcon);
    runBtn.appendChild(document.createTextNode(' Continue'));
    runBtn.onclick = () => this.submit(session, 'append');
    actions.appendChild(runBtn);

    const newBtn = document.createElement('button');
    newBtn.id = 'continue-new-btn';
    newBtn.className = 'btn';
    const newIcon = document.createElement('i');
    newIcon.className = 'fa-solid fa-plus';
    newBtn.appendChild(newIcon);
    newBtn.appendChild(document.createTextNode(' New Session'));
    newBtn.onclick = () => this.submit(session, 'new');
    actions.appendChild(newBtn);

    const forkBtn = document.createElement('button');
    forkBtn.id = 'continue-fork-btn';
    forkBtn.className = 'btn';
    const forkIcon = document.createElement('i');
    forkIcon.className = 'fa-solid fa-code-branch';
    forkBtn.appendChild(forkIcon);
    forkBtn.appendChild(document.createTextNode(' Fork Session'));
    forkBtn.onclick = () => this.submit(session, 'fork');
    actions.appendChild(forkBtn);

    const cancelBtn = document.createElement('button');
    cancelBtn.id = 'continue-cancel-btn';
    cancelBtn.className = 'btn btn--danger';
    cancelBtn.style.display = 'none';
    const cancelIcon = document.createElement('i');
    cancelIcon.className = 'fa-solid fa-stop';
    cancelBtn.appendChild(cancelIcon);
    cancelBtn.appendChild(document.createTextNode(' Cancel'));
    cancelBtn.onclick = () => this.cancel();
    actions.appendChild(cancelBtn);

    box.appendChild(actions);
    container.appendChild(box);

    // Submit on Cmd/Ctrl+Enter
    textarea.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        this.submit(session, 'append');
      }
    });
  },

  _truncate(str, max) {
    if (!str || str.length <= max) return str || '';
    return str.substring(0, max) + '...[truncated]';
  },

  _extractOriginalQuery(session) {
    // Walk through nested "Continue from" prefixes to find the real original query
    let prompt = session.run_start?.prompt || '';
    const prefix = 'Continue from a previous session.\nOriginal query: ';
    while (prompt.startsWith(prefix)) {
      prompt = prompt.substring(prefix.length);
    }
    // Strip anything after "Previous execution history:" to get just the query
    const histIdx = prompt.indexOf('\n\nPrevious execution history:');
    if (histIdx > 0) prompt = prompt.substring(0, histIdx);
    return prompt.trim();
  },

  buildContinuationPrompt(session, followUp) {
    const originalQuery = this._extractOriginalQuery(session);
    const iterations = session.iterations || [];

    let parts = [];
    parts.push('You are continuing from a previous RLM session.');
    parts.push('The REPL state (variables, requires) does NOT persist — you must re-establish any needed state.');
    parts.push('');
    if (originalQuery) parts.push('Original task: ' + originalQuery);
    parts.push('');
    parts.push('Summary of what was done:');

    iterations.forEach(it => {
      const d = it.data || it;
      if (d.action === 'final' || d.action === 'forced_final') {
        parts.push('- Step ' + d.iteration + ' [FINAL]: ' + this._truncate(d.answer || '', 300));
      } else {
        let line = '- Step ' + d.iteration + ': `' + this._truncate((d.code || '').replace(/\n/g, '; '), 150) + '`';
        if (d.execution) {
          if (d.execution.ok) {
            if (d.execution.stdout) line += ' → ' + this._truncate(d.execution.stdout, 200);
            else if (d.execution.value_preview) line += ' → ' + this._truncate(d.execution.value_preview, 200);
            else line += ' → ok';
          } else {
            line += ' → ERROR: ' + (d.execution.error_class || '') + ' ' + this._truncate(d.execution.error_message || '', 150);
          }
        }
        parts.push(line);
      }
    });

    parts.push('');
    parts.push('New request: ' + followUp);
    return parts.join('\n');
  },

  async submit(session, mode = 'append') {
    const textarea = document.getElementById('continue-textarea');
    const followUp = textarea.value.trim();
    if (!followUp) return;

    const isNew = mode === 'new';
    const prompt = isNew ? followUp : this.buildContinuationPrompt(session, followUp);
    const modelSelect = document.getElementById('query-model');
    const model = (modelSelect && modelSelect.value) ? modelSelect.value : 'gemini-3.1-pro-preview';
    const baseSessionId = session.run_start?.run_id;
    const thinkingSelect = document.getElementById('query-thinking');
    const thinkingLevel = thinkingSelect && thinkingSelect.value ? thinkingSelect.value : undefined;
    const environmentConfig = (typeof readExecutionEnvironmentConfig === 'function')
      ? readExecutionEnvironmentConfig()
      : {
        environment: (document.getElementById('query-environment')?.value || 'local'),
        environment_options: (
          document.getElementById('query-environment')?.value === 'docker' &&
          document.getElementById('query-docker-network')?.checked
        ) ? { allow_network: true } : {}
      };

    // Toggle buttons
    document.getElementById('continue-run-btn').style.display = 'none';
    document.getElementById('continue-new-btn').style.display = 'none';
    document.getElementById('continue-fork-btn').style.display = 'none';
    document.getElementById('continue-cancel-btn').style.display = 'inline-flex';
    textarea.disabled = true;

    // The new iteration cards will appear in the container ContinuePrompt was rendered into
    const timeline = this._container || document.getElementById('timeline');
    this.clearRetryNotice();
    // Move the continue prompt box below new cards by removing it temporarily
    const promptBox = document.getElementById('continue-prompt-box');
    if (promptBox) promptBox.remove();

    // Add a divider
    const divider = document.createElement('div');
    divider.className = 'continue-divider';
    divider.textContent = (isNew ? 'New Session: ' : 'Follow-up: ') + followUp;
    timeline.appendChild(divider);

    // Track new iterations for live step count updates
    let newSteps = 0;
    let newOk = 0;
    let newErr = 0;

    try {
      const res = await fetch('/api/query', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          prompt,
          model_name: model,
          thinking_level: thinkingLevel,
          environment: environmentConfig.environment,
          environment_options: environmentConfig.environment_options,
          session_id: isNew ? undefined : baseSessionId,
          fork: !isNew && mode === 'fork'
        })
      });

      if (!res.ok) {
        let detail = '';
        try {
          const err = await res.json();
          detail = err.error || err.message || '';
        } catch (_) {
          detail = (await res.text()) || '';
        }
        const suffix = detail ? (': ' + detail) : '';
        throw new Error('HTTP ' + res.status + suffix);
      }

      const data = await res.json();
      this.activeRunId = data.run_id;
      if (this.activeRunId) history.pushState(null, '', '#' + this.activeRunId);

      this.activeSSE = new SSEClient('/api/query/' + data.run_id + '/stream', {
        onChunk: (event) => {
          if (!this.activeSSE) return;
          if (!this.streamingCard) {
            this.streamingCard = Timeline.buildStreamingCard();
            timeline.appendChild(this.streamingCard);
          }
          const textEl = this.streamingCard.querySelector('.streaming-card__text');
          if (textEl) textEl.textContent = event.accumulated || '';
          this.streamingCard.scrollIntoView({ behavior: 'smooth' });
        },
        onRetry: (event) => {
          this.showRetryNotice(event, timeline);
        },
        onIteration: (event) => {
          this.clearRetryNotice();
          if (this.streamingCard) { this.streamingCard.remove(); this.streamingCard = null; }
          const d = event.data || event;
          const isSubmit = d.action === 'final' || d.action === 'forced_final';
          const isError = !isSubmit && d.execution && !d.execution.ok;
          const card = Timeline.buildCard(d, isSubmit, isError, true, '?');
          card.classList.add('animate-in');
          timeline.appendChild(card);
          if (typeof Prism !== 'undefined') Prism.highlightAll();
          card.scrollIntoView({ behavior: 'smooth' });

          // Update header step counts live
          newSteps++;
          if (isError) newErr++; else newOk++;
          const baseStats = session.stats || {};
          document.getElementById('header-steps-count').textContent = (baseStats.total || 0) + newSteps;
          document.getElementById('header-ok-count').textContent = (baseStats.success || 0) + newOk;
          document.getElementById('header-err-count').textContent = (baseStats.errors || 0) + newErr;
        },
        onComplete: async (event) => {
          this.clearRetryNotice();
          if (this.streamingCard) { this.streamingCard.remove(); this.streamingCard = null; }
          this.resetUI();
          const completedSessionId = event?.session_id || (mode === 'append' ? baseSessionId : this.activeRunId);
          const updated = completedSessionId ? await fetchJSON('/api/sessions/' + completedSessionId).catch(() => null) : null;

          if (updated) {
            App.showSession(updated, { pushState: mode !== 'append' });
            SessionList.activeId = updated.run_start?.run_id || completedSessionId || SessionList.activeId;
          } else {
            ContinuePrompt.render(session, timeline);
          }
          SessionList.load({ preserveSelection: true });
        },
        onError: (err) => {
          this.clearRetryNotice();
          if (this.streamingCard) { this.streamingCard.remove(); this.streamingCard = null; }
          this.resetUI();
          const errDiv = document.createElement('div');
          errDiv.className = 'node';
          errDiv.style.borderColor = 'var(--color-error)';
          errDiv.textContent = 'Error: ' + (err.message || err);
          timeline.appendChild(errDiv);
          ContinuePrompt.render(session, timeline);
        },
        onDisconnect: () => {
          this.clearRetryNotice();
          this.resetUI();
          ContinuePrompt.render(session, timeline);
        }
      });
      this.activeSSE.connect();
    } catch (err) {
      this.resetUI();
      console.error('Continue failed:', err);
    }
  },

  cancel() {
    if (this.activeRunId) {
      fetch('/api/query/' + this.activeRunId, { method: 'DELETE' }).catch(() => { });
    }
    if (this.activeSSE) {
      this.activeSSE.close();
      this.activeSSE = null;
    }
    this.clearRetryNotice();
    this.resetUI();
  },

  showRetryNotice(data, timeline) {
    if (!timeline) return;

    if (!this.retryNoticeEl) {
      this.retryNoticeEl = document.createElement('div');
      this.retryNoticeEl.className = 'retry-notice';
      timeline.appendChild(this.retryNoticeEl);
    }
    const attempt = Number(data.attempt || 0);
    const nextAttempt = Number(data.next_attempt || (attempt + 1));
    const totalAttempts = Number(data.max_retries || 0) + 1;
    const backoff = Number(data.backoff_seconds || 0).toFixed(1);
    const status = data.status_code ? (' [HTTP ' + data.status_code + ']') : '';
    this.retryNoticeEl.textContent = 'Gemini temporary error' + status + '. Retrying attempt ' + nextAttempt + '/' + totalAttempts + ' in ' + backoff + 's...';
  },

  clearRetryNotice() {
    if (this.retryNoticeEl) {
      this.retryNoticeEl.remove();
      this.retryNoticeEl = null;
    }
  },

  resetUI() {
    const runBtn = document.getElementById('continue-run-btn');
    const newBtn = document.getElementById('continue-new-btn');
    const forkBtn = document.getElementById('continue-fork-btn');
    const cancelBtn = document.getElementById('continue-cancel-btn');
    const textarea = document.getElementById('continue-textarea');
    if (runBtn) runBtn.style.display = 'inline-flex';
    if (newBtn) newBtn.style.display = 'inline-flex';
    if (forkBtn) forkBtn.style.display = 'inline-flex';
    if (cancelBtn) cancelBtn.style.display = 'none';
    if (textarea) { textarea.disabled = false; textarea.value = ''; }
    if (this.streamingCard) { this.streamingCard.remove(); this.streamingCard = null; }
    this.clearRetryNotice();
    this.activeSSE = null;
    this.activeRunId = null;
  }
};

// Initialize reliably even when script is injected after DOMContentLoaded.
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => App.init());
} else {
  App.init();
}
