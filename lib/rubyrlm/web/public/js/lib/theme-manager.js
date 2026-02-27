// Theme manager - dark/light toggle with persistence

const ThemeManager = {
  storageKey: 'rubyrlm-theme-v2',

  init() {
    const saved = localStorage.getItem(this.storageKey);
    if (saved) {
      document.documentElement.setAttribute('data-theme', saved);
    }
    this.updateIcon();
  },

  toggle() {
    const current = document.documentElement.getAttribute('data-theme') || 'light';
    const next = current === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    localStorage.setItem(this.storageKey, next);
    this.updateIcon();
    // Notify chart/diagram renderers of theme change
    if (typeof ChartRenderer !== 'undefined') ChartRenderer.onThemeChange(next);
    if (typeof DiagramRenderer !== 'undefined') DiagramRenderer.onThemeChange(next);
  },

  current() {
    return document.documentElement.getAttribute('data-theme') || 'light';
  },

  updateIcon() {
    const icon = document.getElementById('theme-icon');
    if (!icon) return;
    const isDark = this.current() === 'dark';
    icon.className = isDark ? 'fa-solid fa-moon' : 'fa-solid fa-sun';
  }
};

function toggleTheme() { ThemeManager.toggle(); }

ThemeManager.init();
