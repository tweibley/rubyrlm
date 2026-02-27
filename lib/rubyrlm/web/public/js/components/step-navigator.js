// Step navigator component (middle sidebar)

const StepNavigator = {
  steps: [],

  update(session) {
    if (!session) return;

    const iterations = session.iterations || [];
    let successCount = 0, errorCount = 0, submitCount = 0;

    this.steps = iterations.map((it, index) => {
      const d = it.data || it;
      const isSubmit = d.action === 'final' || d.action === 'forced_final';
      const isUserPrompt = d.action === 'user_prompt';
      const isError = !isSubmit && !isUserPrompt && d.execution && !d.execution.ok;

      if (isSubmit) submitCount++;
      else if (isError) errorCount++;
      else if (!isUserPrompt) successCount++;

      return {
        sequence: index + 1,
        iteration: d.iteration,
        action: d.action,
        code: d.code,
        answer: d.answer,
        execution: d.execution,
        isError,
        isSubmit,
        isUserPrompt,
        latency: d.latency_s
      };
    });

    // Show the steps panel
    document.getElementById('steps-sidebar').classList.remove('steps-panel--hidden');

    // Update stats
    document.getElementById('stat-total').textContent = this.steps.length;
    document.getElementById('stat-success').textContent = successCount;
    document.getElementById('stat-error').textContent = errorCount;
    document.getElementById('stat-submits').textContent = submitCount;

    // Animate stat numbers
    Animation.countUp(document.getElementById('stat-total'), this.steps.length);
    Animation.countUp(document.getElementById('stat-success'), successCount);
    Animation.countUp(document.getElementById('stat-error'), errorCount);
    Animation.countUp(document.getElementById('stat-submits'), submitCount);

    // Progress bar
    this.renderProgressBar();

    // Latency sparkline
    this.renderLatencySparkline();

    // Step list
    this.renderStepList();
  },

  renderProgressBar() {
    const bar = document.getElementById('stat-progress');
    bar.textContent = '';
    this.steps.forEach(s => {
      const seg = document.createElement('div');
      seg.className = 'progress-bar__segment';
      if (s.isSubmit) seg.classList.add('progress-bar__segment--final');
      else if (s.isUserPrompt) seg.classList.add('progress-bar__segment--user');
      else if (s.isError) seg.classList.add('progress-bar__segment--err');
      else seg.classList.add('progress-bar__segment--ok');
      bar.appendChild(seg);
    });
  },

  renderLatencySparkline() {
    const wrap = document.getElementById('latency-sparkline-wrap');
    const latencies = this.steps.map(s => s.latency).filter(l => l != null);
    if (latencies.length > 1) {
      wrap.style.display = 'block';
      ChartRenderer.sparkline('latency-sparkline', latencies);
    } else {
      wrap.style.display = 'none';
    }
  },

  renderStepList() {
    const list = document.getElementById('step-list');
    list.textContent = '';

    this.steps.forEach((s, i) => {
      const item = document.createElement('a');
      item.href = '#step-' + s.sequence;
      item.className = 'step-item animate-in';
      item.style.setProperty('--i', i);
      item.addEventListener('click', (e) => {
        e.preventDefault();
        document.querySelectorAll('.step-item').forEach(m => m.classList.remove('step-item--active'));
        item.classList.add('step-item--active');
        const target = document.getElementById('step-' + s.sequence);
        if (target) target.scrollIntoView({ behavior: 'smooth' });
      });

      const num = document.createElement('span');
      num.className = 'step-item__num';
      num.textContent = s.sequence;
      item.appendChild(num);

      const text = document.createElement('span');
      text.className = 'step-item__text';
      if (s.isSubmit) text.textContent = 'Final Answer';
      else if (s.isUserPrompt) text.textContent = 'Follow-up Request';
      else text.textContent = truncate((s.code || s.action || '').replace(/\n/g, ' '), 30);
      item.appendChild(text);

      const badge = document.createElement('span');
      badge.className = 'step-item__badge';
      if (s.isSubmit) badge.textContent = '\u{1F3C1}';
      else if (s.isUserPrompt) badge.textContent = '\u{1F4AC}';
      else badge.textContent = s.isError ? '\u{274C}' : '\u{2705}';
      item.appendChild(badge);

      list.appendChild(item);
    });
  },

  hide() {
    document.getElementById('steps-sidebar').classList.add('steps-panel--hidden');
  }
};
