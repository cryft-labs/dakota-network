const navToggle = document.querySelector('.nav-toggle');
const siteNav = document.querySelector('.site-nav');

if (navToggle && siteNav) {
  navToggle.addEventListener('click', () => {
    const isOpen = siteNav.classList.toggle('is-open');
    navToggle.setAttribute('aria-expanded', String(isOpen));
  });

  siteNav.querySelectorAll('a').forEach((link) => {
    link.addEventListener('click', () => {
      siteNav.classList.remove('is-open');
      navToggle.setAttribute('aria-expanded', 'false');
    });
  });
}

const filters = document.querySelectorAll('.filter-button');
const contractCards = document.querySelectorAll('.contract-card');
const backToTopLink = document.querySelector('[data-back-to-top]');

filters.forEach((button) => {
  button.addEventListener('click', () => {
    filters.forEach((item) => item.classList.remove('is-active'));
    button.classList.add('is-active');

    const selectedGroup = button.dataset.filter;
    contractCards.forEach((card) => {
      const groups = (card.dataset.group || '').split(/\s+/).filter(Boolean);
      const matches = selectedGroup === 'all' || groups.includes(selectedGroup);
      card.classList.toggle('is-hidden', !matches);
    });
  });
});

if (backToTopLink) {
  backToTopLink.addEventListener('click', (event) => {
    event.preventDefault();
    window.scrollTo({
      top: 0,
      behavior: 'smooth',
    });
  });
}

const copyButtons = document.querySelectorAll('[data-copy]');

copyButtons.forEach((button) => {
  button.addEventListener('click', async () => {
    const labelNode = button.querySelector('[data-copy-label]') || button.querySelector('span');
    const originalText = labelNode ? labelNode.textContent : '';
    const value = button.dataset.copy;

    try {
      await navigator.clipboard.writeText(value || '');
      button.classList.add('is-copied');
      if (labelNode) {
        labelNode.textContent = 'Copied';
      }

      window.setTimeout(() => {
        button.classList.remove('is-copied');
        if (labelNode) {
          labelNode.textContent = originalText;
        }
      }, 1600);
    } catch (error) {
      if (labelNode) {
        labelNode.textContent = 'Clipboard unavailable';
      }

      window.setTimeout(() => {
        if (labelNode) {
          labelNode.textContent = originalText;
        }
      }, 1600);
    }
  });
});

const reveals = document.querySelectorAll('.reveal');

const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    });
  },
  {
    threshold: 0.16,
  }
);

reveals.forEach((section) => observer.observe(section));

const rpcEndpoints = [
  'https://rpc1.dakota.cards',
  'https://rpc2.dakota.cards',
];

function getNextRpcEndpoint() {
  try {
    const storageKey = 'dakota-rpc-endpoint-index';
    const storedValue = window.localStorage.getItem(storageKey);
    const currentIndex = Number.parseInt(storedValue || '0', 10);
    const normalizedIndex = Number.isNaN(currentIndex) ? 0 : Math.abs(currentIndex) % rpcEndpoints.length;

    window.localStorage.setItem(storageKey, String((normalizedIndex + 1) % rpcEndpoints.length));
    return rpcEndpoints[normalizedIndex];
  } catch (error) {
    return rpcEndpoints[0];
  }
}

const selectedRpcEndpoint = getNextRpcEndpoint();

const rpcConfig = {
  endpoint: selectedRpcEndpoint,
  refreshMs: 10000,
};

const statsRuntime = {
  latestBlockTimestamp: null,
  lastRefreshAt: null,
};

const statsElements = {
  endpoint: document.querySelector('#rpc-endpoint'),
  modeLabel: document.querySelector('#rpc-mode-label'),
  statusText: document.querySelector('#rpc-status-text'),
  blockNumber: document.querySelector('#stat-block-number'),
  blockAge: document.querySelector('#stat-block-age'),
  gasPrice: document.querySelector('#stat-gas-price'),
  gasUsage: document.querySelector('#stat-gas-usage'),
  syncStatus: document.querySelector('#stat-sync-status'),
  chainId: document.querySelector('#stat-chain-id'),
  clientName: document.querySelector('#stat-client-name'),
  refreshTime: document.querySelector('#stat-refresh-time'),
  refreshButton: document.querySelector('#refresh-stats'),
};

function setStatusTone(element, tone) {
  if (!element) {
    return;
  }

  element.classList.remove('rpc-good', 'rpc-warn', 'rpc-bad');

  if (tone) {
    element.classList.add(tone);
  }
}

function formatHexNumber(hexValue) {
  if (!hexValue) {
    return null;
  }

  return Number.parseInt(hexValue, 16);
}

function formatGwei(hexValue) {
  const wei = formatHexNumber(hexValue);

  if (wei === null || Number.isNaN(wei)) {
    return '--';
  }

  return `${(wei / 1e9).toFixed(9)} gwei`;
}

function formatNumber(value) {
  return new Intl.NumberFormat('en-US').format(value);
}

function formatBlockAge(blockTimestamp) {
  if (!blockTimestamp) {
    return 'Timestamp unavailable';
  }

  const deltaSeconds = Math.max(0, Math.floor(Date.now() / 1000) - blockTimestamp);

  if (deltaSeconds < 5) {
    return 'Produced moments ago';
  }

  if (deltaSeconds < 60) {
    return `${deltaSeconds}s ago`;
  }

  const minutes = Math.floor(deltaSeconds / 60);
  if (minutes < 60) {
    return `${minutes}m ago`;
  }

  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}

function formatRefreshAge(lastRefreshAt) {
  if (!lastRefreshAt) {
    return 'Not updated yet';
  }

  const deltaSeconds = Math.max(0, Math.floor((Date.now() - lastRefreshAt) / 1000));
  const timeLabel = new Date(lastRefreshAt).toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });

  if (deltaSeconds < 2) {
    return `Updated ${timeLabel} just now`;
  }

  return `Updated ${timeLabel} · ${deltaSeconds}s ago`;
}

function updateLiveStatTimers() {
  if (statsElements.blockAge) {
    statsElements.blockAge.textContent = formatBlockAge(statsRuntime.latestBlockTimestamp);
  }

  if (statsElements.refreshTime) {
    statsElements.refreshTime.textContent = formatRefreshAge(statsRuntime.lastRefreshAt);
  }
}

function formatClientName(clientVersion) {
  if (!clientVersion) {
    return '--';
  }

  const [clientName] = clientVersion.split('/');
  return clientName;
}

async function rpcRequest(endpoint, method, params) {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      jsonrpc: '2.0',
      method,
      params,
      id: `${method}-${Date.now()}`,
    }),
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  const payload = await response.json();

  if (payload.error) {
    throw new Error(payload.error.message || 'RPC error');
  }

  return payload.result;
}

async function rpcBatchRequest(endpoint, requests) {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(
      requests.map((request, index) => ({
        jsonrpc: '2.0',
        method: request.method,
        params: request.params,
        id: index + 1,
      }))
    ),
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  const payload = await response.json();

  if (!Array.isArray(payload)) {
    throw new Error('Unexpected RPC batch response');
  }

  const resultsById = new Map(payload.map((entry) => [entry.id, entry]));

  return requests.map((_, index) => {
    const result = resultsById.get(index + 1);

    if (!result) {
      throw new Error('Incomplete RPC batch response');
    }

    if (result.error) {
      throw new Error(result.error.message || 'RPC error');
    }

    return result.result;
  });
}

async function fetchLiveStats() {
  const requests = [
    { method: 'eth_chainId', params: [] },
    { method: 'eth_blockNumber', params: [] },
    { method: 'web3_clientVersion', params: [] },
    { method: 'eth_gasPrice', params: [] },
    { method: 'eth_syncing', params: [] },
    { method: 'eth_getBlockByNumber', params: ['latest', false] },
  ];

  const [chainId, blockNumber, clientVersion, gasPrice, syncing, latestBlock] = await rpcBatchRequest(rpcConfig.endpoint, requests);

  return {
    endpoint: rpcConfig.endpoint,
    chainId,
    blockNumber,
    clientVersion,
    gasPrice,
    syncing,
    latestBlock,
  };
}

function renderLiveStats(data) {
  const blockNumber = formatHexNumber(data.blockNumber);
  const gasUsed = formatHexNumber(data.latestBlock?.gasUsed);
  const gasLimit = formatHexNumber(data.latestBlock?.gasLimit);
  const chainId = formatHexNumber(data.chainId);
  const clientName = formatClientName(data.clientVersion);
  const blockTimestamp = formatHexNumber(data.latestBlock?.timestamp);
  const syncStatus = data.syncing ? 'Syncing' : 'Healthy';
  const usagePercent = gasLimit ? (((gasUsed || 0) / gasLimit) * 100).toFixed(2) : null;
  const endpointHost = new URL(data.endpoint).host;
  statsRuntime.latestBlockTimestamp = blockTimestamp;
  statsRuntime.lastRefreshAt = Date.now();

  if (statsElements.endpoint) {
    statsElements.endpoint.textContent = endpointHost;
  }

  if (statsElements.modeLabel) {
    statsElements.modeLabel.textContent = `Selected on page load: ${endpointHost}. Polling every ${Math.floor(rpcConfig.refreshMs / 1000)}s`;
  }

  if (statsElements.blockNumber) {
    statsElements.blockNumber.textContent = blockNumber !== null ? formatNumber(blockNumber) : '--';
  }

  if (statsElements.blockAge) {
    statsElements.blockAge.textContent = formatBlockAge(blockTimestamp);
  }

  if (statsElements.gasPrice) {
    statsElements.gasPrice.textContent = formatGwei(data.gasPrice);
  }

  if (statsElements.gasUsage) {
    statsElements.gasUsage.textContent = gasLimit ? `${formatNumber(gasUsed || 0)} / ${formatNumber(gasLimit)} gas (${usagePercent}% used)` : 'Latest gas window unavailable';
  }

  if (statsElements.syncStatus) {
    statsElements.syncStatus.textContent = syncStatus;
    setStatusTone(statsElements.syncStatus, data.syncing ? 'rpc-warn' : 'rpc-good');
  }

  if (statsElements.chainId) {
    statsElements.chainId.textContent = chainId !== null ? `Chain ID ${formatNumber(chainId)}` : 'Chain ID unavailable';
  }

  if (statsElements.clientName) {
    statsElements.clientName.textContent = clientName;
  }

  if (statsElements.refreshTime) {
    statsElements.refreshTime.textContent = formatRefreshAge(statsRuntime.lastRefreshAt);
  }

  if (statsElements.statusText) {
    statsElements.statusText.textContent = `Live stats are polling ${data.endpoint} for this page load. Reloading the page reselects between rpc1 and rpc2; a central API and load-balancing layer can be introduced later without changing the UI contract.`;
    setStatusTone(statsElements.statusText, 'rpc-good');
  }
}

function renderStatsError(error) {
  if (statsElements.endpoint) {
    statsElements.endpoint.textContent = 'Endpoint unavailable';
  }

  if (statsElements.modeLabel) {
    statsElements.modeLabel.textContent = 'No active RPC source';
  }

  if (statsElements.statusText) {
    statsElements.statusText.textContent = `Live stats fetch failed from ${rpcConfig.endpoint}: ${error.message}. Check endpoint reachability and CORS before enabling a central API layer.`;
    setStatusTone(statsElements.statusText, 'rpc-bad');
  }

  if (statsElements.syncStatus) {
    statsElements.syncStatus.textContent = 'Unavailable';
    setStatusTone(statsElements.syncStatus, 'rpc-bad');
  }

  if (statsElements.refreshTime) {
    statsElements.refreshTime.textContent = 'No successful refresh yet';
  }

  statsRuntime.latestBlockTimestamp = null;
}

let statsRequestInFlight = false;

async function refreshLiveStats() {
  if (statsRequestInFlight || document.hidden) {
    return;
  }

  statsRequestInFlight = true;

  if (statsElements.refreshButton) {
    statsElements.refreshButton.disabled = true;
    statsElements.refreshButton.textContent = 'Polling...';
  }

  try {
    const liveStats = await fetchLiveStats();
    renderLiveStats(liveStats);
  } catch (error) {
    renderStatsError(error);
  } finally {
    statsRequestInFlight = false;

    if (statsElements.refreshButton) {
      statsElements.refreshButton.disabled = false;
      statsElements.refreshButton.textContent = 'Poll now';
    }
  }
}

if (statsElements.refreshButton) {
  statsElements.refreshButton.addEventListener('click', refreshLiveStats);
  refreshLiveStats();
  window.setInterval(refreshLiveStats, rpcConfig.refreshMs);
  window.setInterval(updateLiveStatTimers, 1000);
}

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) {
    refreshLiveStats();
  }
});