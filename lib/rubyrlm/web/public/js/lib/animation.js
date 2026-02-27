// Animation utilities

const Animation = {
  staggerChildren(parentEl, selector, delayMs = 50) {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    const children = parentEl.querySelectorAll(selector);
    children.forEach((child, i) => {
      child.style.setProperty('--i', i);
      child.classList.add('animate-in');
    });
  },

  scaleIn(elements, delayMs = 80) {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    const els = elements instanceof NodeList ? elements : [elements];
    els.forEach((el, i) => {
      el.style.setProperty('--i', i);
      el.classList.add('animate-scale');
    });
  },

  countUp(element, target, durationMs = 600) {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      element.textContent = typeof target === 'number' ? formatNumber(target) : target;
      return;
    }

    const start = 0;
    const startTime = performance.now();

    function update(currentTime) {
      const elapsed = currentTime - startTime;
      const progress = Math.min(elapsed / durationMs, 1);
      const eased = 1 - Math.pow(1 - progress, 3); // ease-out cubic
      const current = Math.floor(start + (target - start) * eased);
      element.textContent = formatNumber(current);

      if (progress < 1) requestAnimationFrame(update);
      else element.textContent = formatNumber(target);
    }

    requestAnimationFrame(update);
  }
};
