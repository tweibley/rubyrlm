// Context data inspector - tree view for exploring context

const ContextInspector = {
  render(containerId, data) {
    const container = document.getElementById(containerId);
    if (!container) return;
    container.textContent = '';

    if (data == null) {
      container.textContent = 'No context data';
      return;
    }

    const tree = document.createElement('div');
    tree.className = 'context-tree';
    this.buildTree(tree, data, 0);
    container.appendChild(tree);
  },

  buildTree(parent, data, depth) {
    if (depth > 5) {
      const item = document.createElement('div');
      item.className = 'context-tree__item';
      item.style.setProperty('--depth', depth);
      item.textContent = '...';
      parent.appendChild(item);
      return;
    }

    if (typeof data === 'object' && data !== null) {
      const entries = Array.isArray(data)
        ? data.map((v, i) => [i, v])
        : Object.entries(data);

      entries.forEach(([key, value]) => {
        const item = document.createElement('div');
        item.className = 'context-tree__item';
        item.style.setProperty('--depth', depth);

        const isExpandable = typeof value === 'object' && value !== null;

        if (isExpandable) {
          const toggle = document.createElement('span');
          toggle.className = 'context-tree__toggle';
          toggle.textContent = '\u25B6';
          item.appendChild(toggle);

          const keySpan = document.createElement('span');
          keySpan.className = 'context-tree__key';
          keySpan.textContent = key;
          item.appendChild(keySpan);

          const typeSpan = document.createElement('span');
          typeSpan.className = 'context-tree__type';
          typeSpan.textContent = Array.isArray(value)
            ? ' Array[' + value.length + ']'
            : ' Object{' + Object.keys(value).length + '}';
          item.appendChild(typeSpan);

          const childContainer = document.createElement('div');
          childContainer.style.display = 'none';

          toggle.addEventListener('click', () => {
            const isOpen = childContainer.style.display !== 'none';
            childContainer.style.display = isOpen ? 'none' : 'block';
            toggle.textContent = isOpen ? '\u25B6' : '\u25BC';
          });

          parent.appendChild(item);
          this.buildTree(childContainer, value, depth + 1);
          parent.appendChild(childContainer);
        } else {
          const keySpan = document.createElement('span');
          keySpan.className = 'context-tree__key';
          keySpan.textContent = key + ': ';
          item.appendChild(keySpan);

          const valueSpan = document.createElement('span');
          valueSpan.className = 'context-tree__value';
          valueSpan.textContent = truncate(String(value), 100);
          item.appendChild(valueSpan);

          parent.appendChild(item);
        }
      });
    } else {
      const item = document.createElement('div');
      item.className = 'context-tree__item';
      item.style.setProperty('--depth', depth);
      item.textContent = String(data);
      parent.appendChild(item);
    }
  }
};
