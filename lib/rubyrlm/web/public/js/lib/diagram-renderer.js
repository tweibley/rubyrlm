// Mermaid diagram renderer with theme-aware rendering and zoom/pan controls

const DiagramRenderer = {
  initialized: false,

  init() {
    if (this.initialized) return;
    const isDark = ThemeManager.current() === 'dark';
    mermaid.initialize({
      startOnLoad: false,
      theme: isDark ? 'dark' : 'default',
      flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis' },
      securityLevel: 'loose'
    });
    this.initialized = true;
  },

  async render(containerId, definition) {
    this.init();
    const container = document.getElementById(containerId);
    if (!container) return;

    try {
      const id = 'mermaid-' + Date.now();
      const { svg } = await mermaid.render(id, definition);
      this.mountInteractive(container, svg);
    } catch (err) {
      container.textContent = '';
      const errDiv = document.createElement('div');
      errDiv.style.cssText = 'color:var(--color-error);padding:1rem;font-size:0.8rem;';
      errDiv.textContent = 'Diagram render error: ' + err.message;
      container.appendChild(errDiv);
    }
  },

  onThemeChange() {
    this.initialized = false;
    this.init();
  },

  mountInteractive(container, svgText) {
    container.textContent = '';

    const shell = document.createElement('div');
    shell.className = 'diagram-shell';

    const controls = document.createElement('div');
    controls.className = 'diagram-controls';

    const viewport = document.createElement('div');
    viewport.className = 'diagram-viewport';

    const canvas = document.createElement('div');
    canvas.className = 'diagram-canvas';

    const svgElement = this.svgElementFromString(svgText);
    if (!svgElement) {
      const errDiv = document.createElement('div');
      errDiv.style.cssText = 'color:var(--color-error);padding:1rem;font-size:0.8rem;';
      errDiv.textContent = 'Diagram render error: invalid SVG';
      container.appendChild(errDiv);
      return;
    }
    canvas.appendChild(svgElement);

    viewport.appendChild(canvas);
    shell.appendChild(controls);
    shell.appendChild(viewport);
    container.appendChild(shell);

    const state = {
      scale: 1,
      tx: 0,
      ty: 0,
      minScale: 0.2,
      maxScale: 5
    };

    const applyTransform = () => {
      canvas.style.transform = `translate(${state.tx}px, ${state.ty}px) scale(${state.scale})`;
    };

    const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

    const zoomAtPoint = (factor, anchorX, anchorY) => {
      const nextScale = clamp(state.scale * factor, state.minScale, state.maxScale);
      if (nextScale === state.scale) return;

      const ratio = nextScale / state.scale;
      state.tx = anchorX - ((anchorX - state.tx) * ratio);
      state.ty = anchorY - ((anchorY - state.ty) * ratio);
      state.scale = nextScale;
      applyTransform();
    };

    const fitToView = () => {
      const svgEl = canvas.querySelector('svg');
      if (!svgEl) return;

      const viewportRect = viewport.getBoundingClientRect();
      const padding = 24;
      const bounds = this.diagramBounds(svgEl);
      if (!bounds || !bounds.width || !bounds.height) return;

      const availableW = Math.max(1, viewportRect.width - padding * 2);
      const availableH = Math.max(1, viewportRect.height - padding * 2);
      const fitScale = clamp(Math.min(availableW / bounds.width, availableH / bounds.height), state.minScale, state.maxScale);

      state.scale = fitScale;
      state.tx = ((viewportRect.width - bounds.width * fitScale) / 2) - (bounds.x * fitScale);
      state.ty = ((viewportRect.height - bounds.height * fitScale) / 2) - (bounds.y * fitScale);
      applyTransform();
    };

    const resetView = () => {
      state.scale = 1;
      state.tx = 16;
      state.ty = 16;
      applyTransform();
    };

    const createControlButton = (label, title, onClick) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'diagram-control-btn';
      button.textContent = label;
      button.title = title;
      button.addEventListener('click', onClick);
      controls.appendChild(button);
    };

    createControlButton('-', 'Zoom out', () => {
      const rect = viewport.getBoundingClientRect();
      zoomAtPoint(0.85, rect.width / 2, rect.height / 2);
    });
    createControlButton('+', 'Zoom in', () => {
      const rect = viewport.getBoundingClientRect();
      zoomAtPoint(1.15, rect.width / 2, rect.height / 2);
    });
    createControlButton('Fit', 'Fit diagram', fitToView);
    createControlButton('1:1', 'Reset zoom', resetView);

    let dragging = false;
    let dragStartX = 0;
    let dragStartY = 0;
    let dragTx = 0;
    let dragTy = 0;
    let dragPointerId = null;

    const endDrag = () => {
      if (!dragging) return;
      if (dragPointerId != null && viewport.hasPointerCapture(dragPointerId)) {
        viewport.releasePointerCapture(dragPointerId);
      }
      dragging = false;
      dragPointerId = null;
      viewport.classList.remove('diagram-viewport--dragging');
    };

    viewport.addEventListener('pointerdown', (event) => {
      if (event.button !== 0) return;
      const hitNode = event.target && typeof event.target.closest === 'function' && event.target.closest('.node');
      if (hitNode) return;

      dragging = true;
      dragPointerId = event.pointerId;
      dragStartX = event.clientX;
      dragStartY = event.clientY;
      dragTx = state.tx;
      dragTy = state.ty;
      viewport.classList.add('diagram-viewport--dragging');
      viewport.setPointerCapture(event.pointerId);
      event.preventDefault();
    });

    viewport.addEventListener('pointermove', (event) => {
      if (!dragging || dragPointerId !== event.pointerId) return;
      state.tx = dragTx + (event.clientX - dragStartX);
      state.ty = dragTy + (event.clientY - dragStartY);
      applyTransform();
    });

    viewport.addEventListener('pointerup', (event) => {
      if (dragPointerId === event.pointerId) endDrag();
    });

    viewport.addEventListener('pointercancel', (event) => {
      if (dragPointerId === event.pointerId) endDrag();
    });

    viewport.addEventListener('wheel', (event) => {
      event.preventDefault();
      const rect = viewport.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const y = event.clientY - rect.top;
      const factor = event.deltaY < 0 ? 1.1 : 0.9;
      zoomAtPoint(factor, x, y);
    }, { passive: false });

    requestAnimationFrame(fitToView);
  },

  svgElementFromString(svgText) {
    const parser = new DOMParser();
    const doc = parser.parseFromString(svgText, 'image/svg+xml');
    const svg = doc.documentElement;
    if (!svg || svg.nodeName.toLowerCase() !== 'svg') return null;

    return document.importNode(svg, true);
  },

  diagramBounds(svgEl) {
    const base = svgEl.querySelector('g') || svgEl;
    try {
      const box = base.getBBox();
      if (box.width > 0 && box.height > 0) return box;
    } catch (_) {
      // ignored
    }

    const vb = svgEl.viewBox && svgEl.viewBox.baseVal;
    if (vb && vb.width > 0 && vb.height > 0) {
      return { x: vb.x, y: vb.y, width: vb.width, height: vb.height };
    }

    return {
      x: 0,
      y: 0,
      width: svgEl.clientWidth || 800,
      height: svgEl.clientHeight || 600
    };
  }
};
