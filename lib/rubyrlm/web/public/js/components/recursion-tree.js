// Recursion tree Mermaid component

const RecursionTree = {
  async render(sessionId) {
    try {
      const tree = await fetchJSON('/api/sessions/' + sessionId + '/tree');
      if (!tree.children || tree.children.length === 0) {
        document.getElementById('recursion-tree-container').style.display = 'none';
        return;
      }

      document.getElementById('recursion-tree-container').style.display = 'block';
      const graph = this.buildGraph(tree);
      await DiagramRenderer.render('recursion-tree-diagram', graph.definition);
      this.setupClickHandlers(graph.nodeMap);
    } catch {
      document.getElementById('recursion-tree-container').style.display = 'none';
    }
  },

  buildGraph(tree) {
    const lines = ['graph TD'];
    const nodeMap = {};

    const walk = (node, depth, path) => {
      const nodeId = `R_${path}`;
      const label = 'Run ' + this.escape((node.id || '').substring(0, 8)) +
        (node.model ? '\\n' + this.escape(node.model) : '') +
        (node.iterations ? '\\n' + node.iterations + ' steps' : '');

      lines.push('  ' + nodeId + '["' + label + '"]');
      nodeMap[nodeId] = node.id;

      if (depth === 0) {
        lines.push('  style ' + nodeId + ' fill:#0a2e1a,stroke:#10b981,color:#6ee7b7');
      }

      (node.children || []).forEach((child, idx) => {
        const childPath = `${path}_${idx}`;
        const childId = `R_${childPath}`;
        walk(child, depth + 1, childPath);
        lines.push('  ' + nodeId + ' --> ' + childId);
      });
    };

    walk(tree, 0, '0');
    return { definition: lines.join('\n'), nodeMap };
  },

  setupClickHandlers(nodeMap) {
    const container = document.getElementById('recursion-tree-diagram');
    if (!container) return;

    const nodes = container.querySelectorAll('.node');
    nodes.forEach(node => {
      node.style.cursor = 'pointer';
      node.addEventListener('click', async () => {
        const id = node.id || '';
        const match = id.match(/R_[0-9_]+/);
        if (!match) return;

        const runId = nodeMap[match[0]];
        if (!runId) return;

        try {
          const session = await fetchJSON('/api/sessions/' + runId);
          if (!session) return;

          if (App.currentMode !== 'sessions') switchMode('sessions');
          App.showSession(session, { pushState: true });
          SessionList.activeId = runId;
          SessionList.render();
        } catch (error) {
          console.error('Failed to load recursion node session:', error);
        }
      });
    });
  },

  escape(str) {
    return (str || '').replace(/"/g, "'").replace(/[<>{}|]/g, ' ');
  }
};
