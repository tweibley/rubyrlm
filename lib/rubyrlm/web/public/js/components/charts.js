// Charts component - session-level charts

const Charts = {
  renderSessionCharts(session) {
    // Render a per-iteration token usage stacked bar chart
    const iterations = session.iterations || [];

    // Gather per-iteration usage data
    const usageData = [];
    iterations.forEach(it => {
      const d = it.data || it;
      if (d.usage && (d.usage.prompt_tokens || d.usage.candidate_tokens)) {
        usageData.push({
          label: 'Iter ' + (d.iteration || usageData.length + 1),
          prompt: d.usage.prompt_tokens || 0,
          candidate: d.usage.candidate_tokens || 0
        });
      }
    });

    if (usageData.length === 0) return;

    // Create or reuse the canvas element inside the usage-summary section
    const summaryDiv = document.getElementById('usage-summary');
    if (!summaryDiv) return;

    let chartWrapper = document.getElementById('session-token-chart-wrapper');
    if (!chartWrapper) {
      chartWrapper = document.createElement('div');
      chartWrapper.id = 'session-token-chart-wrapper';
      chartWrapper.className = 'chart-container chart-container--small';
      chartWrapper.style.marginTop = '1rem';

      const canvas = document.createElement('canvas');
      canvas.id = 'session-token-chart';
      chartWrapper.appendChild(canvas);
      summaryDiv.appendChild(chartWrapper);
    }

    // Render stacked bar chart via ChartRenderer
    ChartRenderer.bar('session-token-chart', {
      stacked: true,
      data: {
        labels: usageData.map(d => d.label),
        datasets: [
          {
            label: 'Prompt Tokens',
            data: usageData.map(d => d.prompt),
            backgroundColor: '#10b981',
            stack: 'tokens'
          },
          {
            label: 'Candidate Tokens',
            data: usageData.map(d => d.candidate),
            backgroundColor: '#3b82f6',
            stack: 'tokens'
          }
        ]
      },
      options: {
        scales: {
          x: { stacked: true },
          y: { stacked: true }
        }
      }
    });
  }
};
