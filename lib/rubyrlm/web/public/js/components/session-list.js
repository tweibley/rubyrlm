// Session list component

const SessionList = {
  sessions: [],
  activeId: null,

  async load(opts = {}) {
    try {
      this.sessions = await fetchJSON('/api/sessions');
      this.render();
      if (this.sessions.length === 0) {
        this.activeId = null;
        App.clearSessionView();
        return;
      }

      // If there's a pending session from the URL hash, load that; otherwise load the first
      const pending = App._pendingSessionId;
      const preserveSelection = opts.preserveSelection === true;
      const autoSelect = opts.autoSelect !== false;
      const preferredFromOpts = opts.preferredSessionId;
      const preferred = preferredFromOpts || App.currentSession?.run_start?.run_id || this.activeId;
      if (pending && this.sessions.some(s => s.id === pending)) {
        App._pendingSessionId = null;
        this.select(pending);
      } else if (preserveSelection && preferred && this.sessions.some(s => s.id === preferred)) {
        // Just highlight the active item without re-selecting (which would re-render the view)
        this.activeId = preferred;
        document.querySelectorAll('.session-item').forEach(btn => {
          btn.classList.toggle('session-item--active', btn.dataset.id === preferred);
        });
      } else if (!preserveSelection && autoSelect && this.sessions.length > 0) {
        this.select(this.sessions[0].id);
      } else if (preserveSelection && !preferred) {
        this.activeId = null;
        document.querySelectorAll('.session-item').forEach(btn => {
          btn.classList.remove('session-item--active');
        });
      }
    } catch (err) {
      const list = document.getElementById('session-list');
      list.textContent = '';
      const errDiv = document.createElement('div');
      errDiv.className = 'sidebar__loading';
      errDiv.style.color = 'var(--color-error)';
      errDiv.textContent = 'Error loading sessions';
      list.appendChild(errDiv);
    }
  },

  render() {
    const list = document.getElementById('session-list');
    list.textContent = '';

    if (this.sessions.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'sidebar__loading';
      empty.textContent = 'No sessions found';
      list.appendChild(empty);
      return;
    }

    this.sessions.forEach((s, i) => {
      const btn = document.createElement('button');
      btn.className = 'session-item animate-in';
      btn.style.setProperty('--i', i);
      btn.dataset.id = s.id;
      if (s.id === this.activeId) btn.classList.add('session-item--active');
      btn.addEventListener('click', () => this.select(s.id));

      const nameDiv = document.createElement('div');
      nameDiv.className = 'session-item__name';
      nameDiv.textContent = shortId(s.id);
      btn.appendChild(nameDiv);

      const metaDiv = document.createElement('div');
      metaDiv.className = 'session-item__meta';

      const dateSpan = document.createElement('span');
      dateSpan.textContent = formatDate(s.timestamp);
      metaDiv.appendChild(dateSpan);

      if (s.iterations > 0) {
        const iterSpan = document.createElement('span');
        iterSpan.textContent = s.iterations + ' steps';
        metaDiv.appendChild(iterSpan);
      }

      if (s.errors > 0) {
        const errBadge = document.createElement('span');
        errBadge.className = 'session-item__badge session-item__badge--err';
        errBadge.textContent = s.errors + ' err';
        metaDiv.appendChild(errBadge);
      }

      if (s.total_cost > 0) {
        const costSpan = document.createElement('span');
        costSpan.className = 'session-item__badge';
        costSpan.textContent = '$' + s.total_cost.toFixed(4);
        metaDiv.appendChild(costSpan);
      }

      btn.appendChild(metaDiv);
      list.appendChild(btn);
    });

    // Populate comparison dropdowns
    this.populateCompareDropdowns();
  },

  async select(sessionId) {
    if (this.activeId === sessionId) {
      this.clearSelection();
      return;
    }

    this.activeId = sessionId;

    // Update active state
    document.querySelectorAll('.session-item').forEach(btn => {
      btn.classList.toggle('session-item--active', btn.dataset.id === sessionId);
    });

    try {
      const session = await fetchJSON('/api/sessions/' + sessionId);
      App.showSession(session);
    } catch (err) {
      console.error('Failed to load session:', err);
    }
  },

  clearSelection() {
    this.activeId = null;
    document.querySelectorAll('.session-item').forEach(btn => {
      btn.classList.remove('session-item--active');
    });
    App.clearSessionView();
  },

  populateCompareDropdowns() {
    ['compare-a', 'compare-b'].forEach(id => {
      const select = document.getElementById(id);
      if (!select) return;
      const current = select.value;
      select.textContent = '';
      const defaultOpt = document.createElement('option');
      defaultOpt.value = '';
      defaultOpt.textContent = 'Select session';
      select.appendChild(defaultOpt);

      this.sessions.forEach(s => {
        const opt = document.createElement('option');
        opt.value = s.id;
        opt.textContent = shortId(s.id) + ' (' + s.iterations + ' steps)';
        select.appendChild(opt);
      });
      if (current) select.value = current;
    });
  }
};
