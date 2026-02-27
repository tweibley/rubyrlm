// Chart.js renderer with theme-aware styling

const ChartRenderer = {
  instances: {},

  getThemeColors() {
    const style = getComputedStyle(document.documentElement);
    return {
      text: style.getPropertyValue('--color-text-muted').trim(),
      grid: style.getPropertyValue('--color-border').trim(),
      accent: style.getPropertyValue('--color-accent').trim(),
      error: style.getPropertyValue('--color-error').trim(),
      info: style.getPropertyValue('--color-info').trim(),
      warning: style.getPropertyValue('--color-warning').trim(),
      surface: style.getPropertyValue('--color-surface-1').trim(),
    };
  },

  destroy(canvasId) {
    if (this.instances[canvasId]) {
      this.instances[canvasId].destroy();
      delete this.instances[canvasId];
    }
  },

  sparkline(canvasId, data, color) {
    this.destroy(canvasId);
    const ctx = document.getElementById(canvasId);
    if (!ctx) return;

    const colors = this.getThemeColors();
    this.instances[canvasId] = new Chart(ctx, {
      type: 'line',
      data: {
        labels: data.map((_, i) => i + 1),
        datasets: [{
          data: data,
          borderColor: color || colors.accent,
          backgroundColor: 'transparent',
          borderWidth: 1.5,
          pointRadius: 0,
          tension: 0.3,
          fill: false
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { enabled: false } },
        scales: {
          x: { display: false },
          y: { display: false }
        },
        animation: { duration: 500 }
      }
    });
  },

  bar(canvasId, config) {
    this.destroy(canvasId);
    const ctx = document.getElementById(canvasId);
    if (!ctx) return;

    const colors = this.getThemeColors();
    this.instances[canvasId] = new Chart(ctx, {
      type: 'bar',
      data: config.data,
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { labels: { color: colors.text, font: { size: 11 } } }
        },
        scales: {
          x: { ticks: { color: colors.text, font: { size: 10 } }, grid: { color: colors.grid + '40' } },
          y: { ticks: { color: colors.text, font: { size: 10 } }, grid: { color: colors.grid + '40' }, stacked: config.stacked }
        },
        ...(config.options || {})
      }
    });
  },

  pie(canvasId, config) {
    this.destroy(canvasId);
    const ctx = document.getElementById(canvasId);
    if (!ctx) return;

    const colors = this.getThemeColors();
    this.instances[canvasId] = new Chart(ctx, {
      type: 'doughnut',
      data: config.data,
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: 'bottom', labels: { color: colors.text, font: { size: 11 }, padding: 12 } }
        },
        ...(config.options || {})
      }
    });
  },

  onThemeChange() {
    // Re-render all active charts
    Object.keys(this.instances).forEach(id => {
      const chart = this.instances[id];
      if (chart) {
        const colors = this.getThemeColors();
        if (chart.options.scales?.x) chart.options.scales.x.ticks.color = colors.text;
        if (chart.options.scales?.y) chart.options.scales.y.ticks.color = colors.text;
        if (chart.options.plugins?.legend?.labels) chart.options.plugins.legend.labels.color = colors.text;
        chart.update();
      }
    });
  }
};
