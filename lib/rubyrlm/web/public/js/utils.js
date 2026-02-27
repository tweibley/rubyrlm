// Utility functions for RubyRLM web interface

function escapeHtml(str) {
  if (!str) return '';
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

function truncate(str, maxLen) {
  if (!str) return '';
  return str.length > maxLen ? str.substring(0, maxLen) + '...' : str;
}

function formatDuration(seconds) {
  if (seconds == null) return '';
  if (seconds < 1) return (seconds * 1000).toFixed(0) + 'ms';
  return seconds.toFixed(2) + 's';
}

function formatNumber(n) {
  if (n == null) return '0';
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return n.toString();
}

function formatDate(isoStr) {
  if (!isoStr) return 'Unknown';
  try {
    return new Date(isoStr).toLocaleString();
  } catch { return isoStr; }
}

function shortId(id) {
  if (!id) return '';
  return id.substring(0, 8);
}

async function fetchJSON(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

function readExecutionEnvironmentConfig() {
  const environmentSelect = document.getElementById('query-environment');
  const allowNetworkCheckbox = document.getElementById('query-docker-network');
  const environment = (environmentSelect && environmentSelect.value) ? environmentSelect.value : 'local';
  const environment_options = {};

  if (environment === 'docker' && allowNetworkCheckbox && allowNetworkCheckbox.checked) {
    environment_options.allow_network = true;
  }

  return { environment, environment_options };
}
