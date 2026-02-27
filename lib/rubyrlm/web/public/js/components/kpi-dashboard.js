// KPI Dashboard component for analytics view

const KPIDashboard = {
  async load(days = null) {
    try {
      const url = days && days > 0 ? `/api/analytics?days=${days}` : '/api/analytics';
      const data = await fetchJSON(url);
      this.render(data);
    } catch (err) {
      const grid = document.getElementById('kpi-section');
      grid.textContent = '';
      const errDiv = document.createElement('div');
      errDiv.className = 'node';
      errDiv.textContent = 'Failed to load analytics: ' + err.message;
      grid.appendChild(errDiv);
    }
  },

  render(data) {
    if (data.total_sessions === 0) {
      const grid = document.getElementById('kpi-section');
      grid.textContent = '';
      const empty = document.createElement('div');
      empty.className = 'main-view__empty';
      empty.style.gridColumn = '1 / -1';
      const icon = document.createElement('i');
      icon.className = 'fa-solid fa-chart-pie';
      empty.appendChild(icon);
      const msg = document.createElement('p');
      msg.textContent = 'No session data available. Run some queries to see analytics.';
      empty.appendChild(msg);
      grid.appendChild(empty);
      return;
    }
    this.renderKPIs(data);
    this.renderTokenChart(data);
    this.renderModelChart(data);
    this.renderErrorChart(data);
  },

  renderKPIs(data) {
    const grid = document.getElementById('kpi-section');
    grid.textContent = '';

    const kpis = [
      { label: 'Total Sessions', value: data.total_sessions, format: 'number', status: null, icon: 'fa-list-check' },
      { label: 'Avg Steps/Session', value: data.avg_iterations_per_session, format: 'decimal', status: null, icon: 'fa-shoe-prints' },
      { label: 'Total Tokens', value: data.total_tokens, format: 'number', status: null, icon: 'fa-coins' },
      { label: 'Total Cost', value: data.total_cost, format: 'cost', status: null, icon: 'fa-dollar-sign' },
      {
        label: 'Success Rate', value: data.success_rate, format: 'percent',
        status: data.success_rate >= 90 ? 'healthy' : data.success_rate >= 70 ? 'warning' : 'critical', icon: 'fa-circle-check'
      },
      { label: 'Avg Latency', value: data.avg_latency_per_iteration, format: 'duration', status: null, icon: 'fa-clock' },
      {
        label: 'Repair Rate', value: data.repair_rate, format: 'percent',
        status: data.repair_rate <= 5 ? 'healthy' : data.repair_rate <= 15 ? 'warning' : 'critical', icon: 'fa-wrench'
      }
    ];

    kpis.forEach((kpi, i) => {
      const card = document.createElement('div');
      card.className = 'kpi-card';
      card.style.setProperty('--i', i);
      card.classList.add('animate-scale');

      const label = document.createElement('div');
      label.className = 'kpi-card__label';
      if (kpi.icon) {
        const icon = document.createElement('i');
        icon.className = 'fa-solid ' + kpi.icon;
        icon.style.marginRight = '0.5rem';
        label.appendChild(icon);
      }
      label.appendChild(document.createTextNode(kpi.label));
      card.appendChild(label);

      const value = document.createElement('div');
      value.className = 'kpi-card__value';
      switch (kpi.format) {
        case 'number': value.textContent = formatNumber(kpi.value); break;
        case 'decimal': value.textContent = (kpi.value || 0).toFixed(1); break;
        case 'percent': value.textContent = (kpi.value || 0).toFixed(1) + '%'; break;
        case 'duration': value.textContent = formatDuration(kpi.value); break;
        case 'cost': value.textContent = '$' + (kpi.value || 0).toFixed(4); break;
        default: value.textContent = kpi.value;
      }
      card.appendChild(value);

      if (kpi.status) {
        const badge = document.createElement('div');
        badge.className = 'kpi-card__status kpi-card__status--' + kpi.status;
        badge.textContent = kpi.status.charAt(0).toUpperCase() + kpi.status.slice(1);
        card.appendChild(badge);
      }

      grid.appendChild(card);
    });
  },

  renderTokenChart(data) {
    const series = data.time_series || [];
    if (series.length === 0) return;

    const colors = ChartRenderer.getThemeColors();
    ChartRenderer.bar('token-chart', {
      stacked: true,
      data: {
        labels: series.map(s => s.date),
        datasets: [
          {
            label: 'Prompt Tokens',
            data: series.map(s => s.prompt_tokens || 0),
            backgroundColor: colors.accent + '80'
          },
          {
            label: 'Candidate Tokens',
            data: series.map(s => s.candidate_tokens || 0),
            backgroundColor: colors.info + '60'
          },
          {
            label: 'Cached Tokens',
            data: series.map(s => s.cached_content_tokens || 0),
            backgroundColor: colors.success + '60'
          }
        ]
      }
    });
  },

  renderModelChart(data) {
    const models = data.model_breakdown || {};
    const entries = Object.entries(models);
    if (entries.length === 0) return;

    const palette = ['#10b981', '#3b82f6', '#f59e0b', '#ef4444', '#8b5cf6'];
    ChartRenderer.pie('model-chart', {
      data: {
        labels: entries.map(([m]) => m),
        datasets: [{
          data: entries.map(([, v]) => v.sessions),
          backgroundColor: entries.map((_, i) => palette[i % palette.length] + 'cc')
        }]
      }
    });
  },

  renderErrorChart(data) {
    const errors = data.top_error_classes || {};
    const entries = Object.entries(errors);
    if (entries.length === 0) {
      const container = document.getElementById('error-analysis');
      if (container) {
        const msg = document.createElement('div');
        msg.style.cssText = 'padding:2rem;text-align:center;color:var(--color-text-muted);';
        msg.textContent = 'No errors recorded';
        container.querySelector('.chart-container')?.appendChild(msg);
      }
      return;
    }

    const colors = ChartRenderer.getThemeColors();
    ChartRenderer.bar('error-chart', {
      data: {
        labels: entries.map(([cls]) => cls),
        datasets: [{
          label: 'Count',
          data: entries.map(([, count]) => count),
          backgroundColor: colors.error + '80'
        }]
      }
    });
  },

  init() {
    const filter = document.getElementById('kpi-time-filter');
    if (filter) {
      filter.addEventListener('change', (e) => {
        this.load(e.target.value);
      });
    }
  }
};

document.addEventListener('DOMContentLoaded', () => {
  KPIDashboard.init();
});
