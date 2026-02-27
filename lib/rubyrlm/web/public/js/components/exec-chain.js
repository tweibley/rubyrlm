// Exec chain Mermaid flowchart component

const ExecChain = {
  async render(session) {
    const iterations = session.iterations || [];
    if (iterations.length === 0) return;

    const definition = this.buildDefinition(session);
    await DiagramRenderer.render('exec-chain-diagram', definition);
    this.setupClickHandlers();
  },

  setupClickHandlers() {
    const container = document.getElementById('exec-chain-diagram');
    if (!container) return;

    // Mermaid creates SVG nodes with class 'node'
    const nodes = container.querySelectorAll('.node');
    nodes.forEach(node => {
      node.style.cursor = 'pointer';
      node.addEventListener('click', () => {
        // Extract sequence number from node ID
        const id = node.id || '';
        const match = id.match(/N(\d+)/);
        if (match) {
          const stepId = 'step-' + match[1];
          const target = document.getElementById(stepId);
          if (target) {
            // Switch to timeline view if in flow view
            if (App.currentView === 'flow') {
              setView('timeline');
            }
            setTimeout(() => {
              target.scrollIntoView({ behavior: 'smooth' });
              target.classList.add('timeline-card--expanded');
              // Flash highlight
              target.style.boxShadow = '0 0 0 2px var(--color-accent)';
              setTimeout(() => { target.style.boxShadow = ''; }, 2000);
            }, 100);
          }
        }
      });
    });
  },

  buildDefinition(session) {
    const iterations = session.iterations || [];
    const prompt = session.run_start?.prompt || 'Query';
    let lines = ['graph TD'];

    lines.push('  S["' + this.escape(truncate(prompt, 40)) + '"]');

    iterations.forEach((it, i) => {
      const d = it.data || it;
      const sequence = i + 1
      const nodeId = 'N' + sequence;
      const isSubmit = d.action === 'final' || d.action === 'forced_final';
      const isError = !isSubmit && d.execution && !d.execution.ok;

      if (isSubmit) {
        const label = this.escape(truncate(d.answer || 'Final', 30));
        lines.push('  ' + nodeId + '["' + label + '"]');
        lines.push('  style ' + nodeId + ' fill:#1e3a5f,stroke:#3b82f6,color:#93c5fd');
      } else {
        const codeLine = (d.code || '').split('\n')[0];
        const label = this.escape(truncate(codeLine, 35));
        lines.push('  ' + nodeId + '["Exec ' + d.iteration + ': ' + label + '"]');

        if (isError) {
          lines.push('  style ' + nodeId + ' fill:#3b1010,stroke:#ef4444,color:#fca5a5');
        } else {
          lines.push('  style ' + nodeId + ' fill:#0a2e1a,stroke:#10b981,color:#6ee7b7');
        }
      }

      // Edges
      const prevId = i === 0 ? 'S' : ('N' + i);
      let edgeLabel = '';

      if (i > 0) {
        const prevD = iterations[i - 1].data || iterations[i - 1];
        if (prevD.execution) {
          if (!prevD.execution.ok) {
            edgeLabel = this.escape(truncate(prevD.execution.error_class || 'error', 20));
          } else if (prevD.execution.value_preview) {
            edgeLabel = this.escape(truncate(prevD.execution.value_preview, 20));
          }
        }
      }

      if (edgeLabel) {
        lines.push('  ' + prevId + ' -->|"' + edgeLabel + '"| ' + nodeId);
      } else {
        lines.push('  ' + prevId + ' --> ' + nodeId);
      }
    });

    lines.push('  style S fill:#1a1a1a,stroke:#888,color:#e5e5e5');
    return lines.join('\n');
  },

  escape(str) {
    return (str || '').replace(/"/g, "'").replace(/[<>{}|]/g, ' ');
  }
};
