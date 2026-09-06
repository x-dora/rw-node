#!/usr/bin/env node
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const net = require('net');
const http = require('http');
const crypto = require('crypto');
const path = require('path');

const LOG_PREFIX = process.env.LOG_PREFIX || '[rw-node]';
const INTERNAL_REST_PORT = process.env.INTERNAL_REST_PORT || '61001';
const CADDY_ADMIN_SOCK = process.env.CADDY_ADMIN_SOCK || '/tmp/caddy-admin.sock';
const CADDY_BIN = process.env.CADDY_BIN || 'caddy';
const INBOUND_WATCHER_INTERVAL = parseInt(process.env.INBOUND_WATCHER_INTERVAL || '15', 10) * 1000;
const HTTP_FRONT_PORT = process.env.HTTP_FRONT_PORT || '3000';
const NODE_PORT = process.env.NODE_PORT || '2222';
const XHTTP_UPSTREAM_PORT = process.env.XHTTP_UPSTREAM_PORT || '8080';
const WS_UPSTREAM_PORT = process.env.WS_UPSTREAM_PORT || '8880';
const CADDY_SITE_DIR = process.env.CADDY_SITE_DIR || '';


function log(msg) {
  console.log(`${LOG_PREFIX} ${msg}`);
}

function httpGet(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: 5000 }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve(data));
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
  });
}

function normalizePath(p) {
  if (!p) return '';
  let normalized = p.split('?')[0].split('#')[0];
  if (normalized && !normalized.startsWith('/')) normalized = '/' + normalized;
  return normalized;
}

function getHttpPath(streamSettings) {
  const network = streamSettings.network;
  switch (network) {
    case 'ws':
      return (streamSettings.wsSettings || {}).path || '';
    case 'xhttp':
      return (streamSettings.xhttpSettings || {}).path || '';
    case 'httpupgrade':
      return (streamSettings.httpupgradeSettings || {}).path || '';
    default:
      return '';
  }
}

function extractInboundConfig(config) {
  const inbounds = config.inbounds || [];
  const realityRoutes = [];
  const httpPathCandidates = [];

  for (const ib of inbounds) {
    const stream = ib.streamSettings;
    if (!stream) continue;

    if (stream.security === 'reality') {
      const names = (stream.realitySettings || {}).serverNames || [];
      if (names.length > 0 && ib.port) {
        realityRoutes.push({ port: ib.port, serverNames: names });
      }
      continue;
    }

    const network = stream.network;
    if (network === 'ws' || network === 'xhttp' || network === 'httpupgrade') {
      const rawPath = getHttpPath(stream);
      const normalizedPath = normalizePath(rawPath);
      if (normalizedPath) {
        httpPathCandidates.push({
          path: normalizedPath,
          port: ib.port,
          network,
          tag: ib.tag || `port:${ib.port}`,
        });
      }
    }
  }

  const mergedReality = mergeRealityRoutes(realityRoutes);
  const { routes: httpRoutes, conflicts } = resolveHttpRoutes(httpPathCandidates);
  const panelSni = typeof config.panelSni === 'string' ? config.panelSni : '';

  return { realityRoutes: mergedReality, httpRoutes, conflicts, panelSni };
}

function mergeRealityRoutes(routes) {
  const byPort = new Map();
  for (const r of routes) {
    const existing = byPort.get(r.port) || new Set();
    for (const n of r.serverNames) existing.add(n);
    byPort.set(r.port, existing);
  }
  const result = [];
  for (const [port, names] of byPort) {
    result.push({ port, serverNames: [...names].sort() });
  }
  return result;
}

function resolveHttpRoutes(candidates) {
  const byPath = new Map();
  for (const c of candidates) {
    const existing = byPath.get(c.path) || [];
    existing.push(c);
    byPath.set(c.path, existing);
  }

  const routes = [];
  const conflicts = [];

  for (const [p, entries] of byPath) {
    const ports = new Set(entries.map((e) => e.port));
    if (ports.size === 1) {
      routes.push(entries[0]);
    } else {
      conflicts.push({ path: p, tags: entries.map((e) => `${e.tag}(port:${e.port})`) });
    }
  }

  routes.sort((a, b) => b.path.length - a.path.length);
  return { routes, conflicts };
}

function generateL4RouteBlock(realityRoutes, panelSni) {
  const lines = [];
  if (panelSni) {
    lines.push(`                @panel tls sni ${panelSni}`);
    lines.push(`                route @panel {`);
    lines.push(`                    proxy 127.0.0.1:${NODE_PORT}`);
    lines.push(`                }`);
  }
  for (const r of realityRoutes) {
    const snis = r.serverNames.join(' ');
    const matcherName = realityRoutes.length === 1 ? 'reality' : `reality_${r.port}`;
    lines.push(`                @${matcherName} tls sni ${snis}`);
    lines.push(`                route @${matcherName} {`);
    lines.push(`                    proxy 127.0.0.1:${r.port}`);
    lines.push(`                }`);
  }
  return lines.join('\n');
}

function generateHttpRouteBlock(httpRoutes) {
  if (httpRoutes.length === 0) {
    const lines = [];
    lines.push(`    handle /xh-* {`);
    lines.push(`        reverse_proxy 127.0.0.1:${XHTTP_UPSTREAM_PORT} {`);
    lines.push(`            flush_interval -1`);
    lines.push(`        }`);
    lines.push(`    }`);
    lines.push(``);
    lines.push(`    handle /ws-* {`);
    lines.push(`        reverse_proxy 127.0.0.1:${WS_UPSTREAM_PORT} {`);
    lines.push(`            flush_interval -1`);
    lines.push(`        }`);
    lines.push(`    }`);
    return lines.join('\n');
  }

  const lines = [];
  for (const r of httpRoutes) {
    const pathPattern = r.path.endsWith('*') ? r.path : `${r.path}*`;
    lines.push(`    handle ${pathPattern} {`);
    lines.push(`        reverse_proxy 127.0.0.1:${r.port} {`);
    lines.push(`            flush_interval -1`);
    lines.push(`        }`);
    lines.push(`    }`);
    if (r !== httpRoutes[httpRoutes.length - 1]) lines.push(``);
  }
  return lines.join('\n');
}

function generateCaddyConfig(l4Block, httpBlock, panelSni) {
  const templatePath = path.join(__dirname, 'Caddyfile.template');
  let content = fs.readFileSync(templatePath, 'utf8');

  const adminLine = (process.env.INBOUND_WATCHER_ENABLED || 'true') !== 'false'
    ? `admin unix/${CADDY_ADMIN_SOCK}`
    : 'admin off';

  // Upstream SNI for the node API when SNI_VERIFICATION is enabled on the
  // node; the derived hostname is public tooling metadata, not a secret.
  const tlsServerNameLine = panelSni ? `                tls_server_name ${panelSni}` : '';

  content = content
    .replace(/\$\{CADDY_ADMIN_LINE\}/g, adminLine)
    .replace(/\$\{L4_ROUTE_BLOCK\}/g, l4Block)
    .replace(/\$\{HTTP_ROUTE_BLOCK\}/g, httpBlock)
    .replace(/\$\{HTTP_FRONT_PORT\}/g, HTTP_FRONT_PORT)
    .replace(/\$\{NODE_PORT\}/g, NODE_PORT)
    .replace(/\$\{NODE_TLS_SERVER_NAME\}/g, tlsServerNameLine)
    .replace(/\$\{CADDY_SITE_DIR\}/g, CADDY_SITE_DIR);

  return content;
}

function hashString(s) {
  return crypto.createHash('md5').update(s).digest('hex');
}

function caddyFmt(configPath) {
  try {
    execFileSync(CADDY_BIN, ['fmt', '--overwrite', configPath], { stdio: 'pipe', timeout: 5000 });
  } catch {
    // ignore format errors
  }
}

function caddyReload(configPath) {
  try {
    execFileSync(CADDY_BIN, [
      'reload', '--config', configPath, '--adapter', 'caddyfile',
      '--address', `unix/${CADDY_ADMIN_SOCK}`,
    ], { stdio: 'pipe', timeout: 10000 });
    return true;
  } catch {
    return false;
  }
}

function checkPort(port) {
  return new Promise((resolve, reject) => {
    const socket = new net.Socket();
    socket.setTimeout(2000);
    socket.on('connect', () => { socket.destroy(); resolve(); });
    socket.on('error', (err) => { socket.destroy(); reject(err); });
    socket.on('timeout', () => { socket.destroy(); reject(new Error('timeout')); });
    socket.connect(parseInt(port, 10), '127.0.0.1');
  });
}

async function waitForPort(port, maxWait) {
  const end = Date.now() + maxWait;
  while (Date.now() < end) {
    try {
      await checkPort(port);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
}

async function main(configPath) {
  if (!configPath) {
    configPath = process.argv[2];
  }
  if (!configPath) {
    console.error(`${LOG_PREFIX} ERROR: inbound-watcher.js requires config_path argument`);
    process.exit(1);
  }

  await waitForPort(INTERNAL_REST_PORT, 120000);

  let prevHash = '';
  let firstRun = true;

  while (true) {
    if (firstRun) {
      firstRun = false;
    } else {
      await new Promise((r) => setTimeout(r, INBOUND_WATCHER_INTERVAL));
    }

    let configJson;
    try {
      const raw = await httpGet(`http://127.0.0.1:${INTERNAL_REST_PORT}/internal/get-config`);
      configJson = JSON.parse(raw);
    } catch {
      continue;
    }

    if (!configJson) continue;

    const { realityRoutes, httpRoutes, conflicts, panelSni } = extractInboundConfig(configJson);

    const hashInput = JSON.stringify({ realityRoutes, httpRoutes, panelSni });
    const currentHash = hashString(hashInput);
    if (currentHash === prevHash) continue;
    prevHash = currentHash;

    for (const c of conflicts) {
      log(`WARN: HTTP route conflict: path=${c.path} claimed by [${c.tags.join(', ')}], skipped`);
    }

    if (panelSni) {
      log(`L4 route: PANEL sni=${panelSni} -> 127.0.0.1:${NODE_PORT}`);
    }

    if (realityRoutes.length > 0) {
      for (const r of realityRoutes) {
        log(`L4 route: REALITY snis=[${r.serverNames.join(' ')}] -> 127.0.0.1:${r.port}`);
      }
    }

    if (httpRoutes.length > 0) {
      for (const r of httpRoutes) {
        log(`HTTP route: ${r.path} [${r.network}] -> 127.0.0.1:${r.port}`);
      }
    } else if (realityRoutes.length > 0 || conflicts.length > 0) {
      log('No HTTP path inbounds detected, using fallback wildcard routes');
    }

    if (realityRoutes.length === 0 && httpRoutes.length === 0 && conflicts.length === 0) {
      if (panelSni) {
        log('Only panel SNI detected, using default HTTP routes');
      } else {
        log('No routeable inbounds detected, using default config');
      }
    }

    const l4Block = generateL4RouteBlock(realityRoutes, panelSni);
    const httpBlock = generateHttpRouteBlock(httpRoutes);

    fs.writeFileSync(configPath, generateCaddyConfig(l4Block, httpBlock, panelSni));
    caddyFmt(configPath);

    if (caddyReload(configPath)) {
      log('Caddy reloaded with updated inbound routing config');
    } else {
      log('WARN: Caddy reload failed, will retry next cycle');
    }
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`${LOG_PREFIX} ERROR: ${err.message}`);
    process.exit(1);
  });
}

module.exports = { main };
