// Query panel component - submit prompts and stream results

const QueryPanel = {
  activeSSE: null,
  activeRunId: null,
  lastSessionId: null,
  streamingCard: null,
  retryNoticeEl: null,

  init() {
    const environmentSelect = document.getElementById('query-environment');
    const allowNetworkCheckbox = document.getElementById('query-docker-network');
    const keepAliveCheckbox = document.getElementById('query-docker-keep-alive');
    const reuseSelect = document.getElementById('query-docker-reuse-id');
    if (!environmentSelect || !allowNetworkCheckbox) return;

    const syncEnvironmentState = () => {
      const dockerSelected = environmentSelect.value === 'docker';
      allowNetworkCheckbox.disabled = !dockerSelected;
      if (keepAliveCheckbox) keepAliveCheckbox.disabled = !dockerSelected;
      if (reuseSelect) reuseSelect.disabled = !dockerSelected;
      if (!dockerSelected) {
        allowNetworkCheckbox.checked = false;
        if (keepAliveCheckbox) keepAliveCheckbox.checked = false;
        if (reuseSelect) reuseSelect.value = '';
      }
      this.updateWarningBanner();
    };

    environmentSelect.addEventListener('change', syncEnvironmentState);
    allowNetworkCheckbox.addEventListener('change', () => this.updateWarningBanner());
    if (reuseSelect) {
      reuseSelect.addEventListener('focus', () => this.refreshContainers());
    }
    syncEnvironmentState();
    this.refreshContainers();
  },

  async refreshContainers() {
    const reuseSelect = document.getElementById('query-docker-reuse-id');
    if (!reuseSelect) return;
    try {
      const res = await fetch('/api/containers');
      if (res.ok) {
        const containers = await res.json();
        const currentVal = reuseSelect.value;
        reuseSelect.innerHTML = '<option value="">-- New Container --</option>';
        containers.forEach(c => {
          const opt = document.createElement('option');
          opt.value = c.ID;
          opt.textContent = `${c.ID.substring(0, 12)} - ${c.Status}`;
          reuseSelect.appendChild(opt);
        });
        if (Array.from(reuseSelect.options).some(o => o.value === currentVal)) {
          reuseSelect.value = currentVal;
        }
      }
    } catch (_) { }
  },

  updateWarningBanner() {
    const warningEl = document.getElementById('query-warning-banner');
    if (!warningEl) return;

    const { environment } = this.readEnvironmentConfig();
    const message = environment === 'docker'
      ? 'Prompts run inside Docker isolation. Enable network only when required.'
      : 'Prompts execute arbitrary Ruby code locally. Run only trusted instructions.';

    warningEl.textContent = '';
    const icon = document.createElement('i');
    icon.className = 'fa-solid fa-shield-halved';
    warningEl.appendChild(icon);
    warningEl.appendChild(document.createTextNode(' ' + message));
  },

  async submit() {
    const prompt = document.getElementById('query-prompt').value.trim();
    if (!prompt) return;

    const config = {
      model_name: document.getElementById('query-model').value,
      max_iterations: parseInt(document.getElementById('query-max-iter').value) || 30,
      iteration_timeout: parseInt(document.getElementById('query-timeout').value) || 60,
      max_depth: parseInt(document.getElementById('query-max-depth').value) || 1,
      temperature: parseFloat(document.getElementById('query-temp').value) || 0.5
    };
    const thinkingSelect = document.getElementById('query-thinking');
    if (thinkingSelect && thinkingSelect.value) {
      config.thinking_level = thinkingSelect.value;
    }
    const environmentConfig = this.readEnvironmentConfig();
    config.environment = environmentConfig.environment;
    config.environment_options = environmentConfig.environment_options;

    // Clear previous results
    document.getElementById('timeline').textContent = '';
    this.clearRetryNotice();

    // Toggle buttons
    document.getElementById('query-run-btn').style.display = 'none';
    document.getElementById('query-cancel-btn').style.display = 'inline-flex';

    try {
      const body = { prompt, ...config };
      if (this.lastSessionId) {
        body.session_id = this.lastSessionId;
      }
      const res = await fetch('/api/query', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
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
        throw new Error('Failed to start query: HTTP ' + res.status + suffix);
      }

      const data = await res.json();
      this.activeRunId = data.run_id;

      // PIVOT UI: Immediately show the user's prompt locked safely inside the session header.
      if (typeof App !== 'undefined') {
        App.showStreamingSession(this.activeRunId, prompt, config.model_name);
      }

      if (this.activeRunId) history.pushState(null, '', '#' + this.activeRunId);

      // Connect SSE
      this.activeSSE = new SSEClient('/api/query/' + data.run_id + '/stream', {
        onChunk: (event) => this.onChunk(event),
        onRetry: (event) => this.onRetry(event),
        onIteration: (event) => this.onIteration(event),
        onComplete: (event) => this.onComplete(event),
        onError: (err) => this.onError(err),
        onDisconnect: () => this.onDisconnect()
      });
      this.activeSSE.connect();
    } catch (err) {
      this.onError(err);
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
    this.resetButtons();
  },

  onChunk(data) {
    if (!this.activeSSE) return;
    const timeline = document.getElementById('timeline');
    if (!this.streamingCard) {
      this.streamingCard = Timeline.buildStreamingCard();
      timeline.appendChild(this.streamingCard);
    }
    const textEl = this.streamingCard.querySelector('.streaming-card__text');
    if (textEl) textEl.textContent = data.accumulated || '';
    this.streamingCard.scrollIntoView({ behavior: 'smooth' });
  },

  onIteration(data) {
    this.clearRetryNotice();
    if (this.streamingCard) {
      this.streamingCard.remove();
      this.streamingCard = null;
    }
    const timeline = document.getElementById('timeline');
    const d = data.data || data;
    const isSubmit = d.action === 'final' || d.action === 'forced_final';
    const isError = !isSubmit && d.execution && !d.execution.ok;

    const card = Timeline.buildCard(d, isSubmit, isError, true, '?');
    card.classList.add('animate-in');
    timeline.appendChild(card);

    if (typeof Prism !== 'undefined') Prism.highlightAll();
    card.scrollIntoView({ behavior: 'smooth' });
  },

  async onComplete(data) {
    this.clearRetryNotice();
    const finishedRunId = this.activeRunId;
    this.resetButtons();

    const sessionId = data.session_id || finishedRunId;
    this.lastSessionId = sessionId || null;

    // Keep URL in sync
    if (sessionId) {
      history.replaceState(null, '', '#' + sessionId);
    }

    // Update placeholder to hint that the next query will continue this session
    const textarea = document.getElementById('query-prompt');
    if (textarea) {
      textarea.value = '';
      if (sessionId) {
        textarea.placeholder = '>_ Continue session ' + shortId(sessionId) + '...';
      }
    }

    // Silently refresh session list sidebar (no view switching, no re-selection)
    if (sessionId) {
      SessionList.activeId = sessionId;
    }
    SessionList.load({ preserveSelection: true, autoSelect: false });

    // Pre-render the session in the Sessions view (background) so
    // the Continue Session prompt is ready when the user switches views.
    // Also render a ContinuePrompt in the Controller's timeline.
    if (sessionId) {
      try {
        const session = await this.fetchSessionWithRetry(sessionId);
        if (session) {
          App.showSession(session, { pushState: false });
          // Show Continue Session prompt inline in the generic timeline
          const queryTimeline = document.getElementById('timeline');
          if (queryTimeline) {
            ContinuePrompt.render(session, queryTimeline);
          }
        }
      } catch (_) { /* non-critical */ }
    }
  },

  async fetchSessionWithRetry(sessionId, attempts = 6, delayMs = 150) {
    for (let i = 0; i < attempts; i++) {
      try {
        const session = await fetchJSON('/api/sessions/' + sessionId);
        if (session) return session;
      } catch (_) {
        // Session file may not be visible immediately after run completion.
      }

      if (i < attempts - 1) {
        await new Promise(resolve => setTimeout(resolve, delayMs));
      }
    }
    return null;
  },

  onError(err) {
    this.clearRetryNotice();
    this.resetButtons();
    const timeline = document.getElementById('query-timeline');
    const errDiv = document.createElement('div');
    errDiv.className = 'node';
    errDiv.style.borderColor = 'var(--color-error)';
    errDiv.textContent = 'Error: ' + (err.message || err);
    timeline.appendChild(errDiv);
  },

  onDisconnect() {
    this.resetButtons();
  },

  onRetry(data) {
    const timeline = document.getElementById('query-timeline');
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

  readEnvironmentConfig() {
    const environmentSelect = document.getElementById('query-environment');
    const allowNetworkCheckbox = document.getElementById('query-docker-network');
    const keepAliveCheckbox = document.getElementById('query-docker-keep-alive');
    const reuseSelect = document.getElementById('query-docker-reuse-id');
    const environment = (environmentSelect && environmentSelect.value) ? environmentSelect.value : 'local';
    const environment_options = {};

    if (environment === 'docker') {
      if (allowNetworkCheckbox && allowNetworkCheckbox.checked) {
        environment_options.allow_network = true;
      }
      if (keepAliveCheckbox && keepAliveCheckbox.checked) {
        environment_options.keep_alive = true;
      }
      if (reuseSelect && reuseSelect.value) {
        environment_options.reuse_container_id = reuseSelect.value;
      }
    }

    return { environment, environment_options };
  },

  resetButtons() {
    document.getElementById('query-run-btn').style.display = 'inline-flex';
    document.getElementById('query-cancel-btn').style.display = 'none';
    if (this.streamingCard) { this.streamingCard.remove(); this.streamingCard = null; }
    this.clearRetryNotice();
    this.activeSSE = null;
    this.activeRunId = null;
  }
};

function submitQuery() { QueryPanel.submit(); }
function cancelQuery() { QueryPanel.cancel(); }

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => QueryPanel.init());
} else {
  QueryPanel.init();
}
