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
const REALITY_SPLIT_INTERVAL = parseInt(process.env.REALITY_SPLIT_INTERVAL || '15', 10) * 1000;
const HTTP_FRONT_PORT = process.env.HTTP_FRONT_PORT || '3000';
const NODE_PORT = process.env.NODE_PORT || '2222';
const CADDY_HTTP_PORT = process.env.CADDY_HTTP_PORT || String(parseInt(HTTP_FRONT_PORT, 10) + 1);
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

function extractRealityConfig(config) {
  const inbounds = config.inbounds || [];
  const realityInbounds = inbounds.filter(
    (ib) => ib.streamSettings && ib.streamSettings.security === 'reality'
  );

  if (realityInbounds.length === 0) return null;

  const port = realityInbounds[0].port;
  const allNames = new Set();
  for (const ib of realityInbounds) {
    const names = (ib.streamSettings.realitySettings || {}).serverNames || [];
    for (const n of names) allNames.add(n);
  }

  if (allNames.size === 0) return null;

  return { port, serverNames: [...allNames].sort().join(' ') };
}

function generateCaddyConfig(realitySnis, realityPort) {
  const templatePath = path.join(__dirname, 'Caddyfile.template');
  let content = fs.readFileSync(templatePath, 'utf8');

  const adminLine = `admin unix/${CADDY_ADMIN_SOCK}`;
  let realityBlock = '';
  if (realitySnis && realityPort) {
    realityBlock = [
      `            @reality tls sni ${realitySnis}`,
      `            route @reality {`,
      `                proxy 127.0.0.1:${realityPort}`,
      `            }`,
    ].join('\n');
  }

  content = content
    .replace(/\$\{CADDY_ADMIN_LINE\}/g, adminLine)
    .replace(/\$\{REALITY_ROUTE_BLOCK\}/g, realityBlock)
    .replace(/\$\{HTTP_FRONT_PORT\}/g, HTTP_FRONT_PORT)
    .replace(/\$\{NODE_PORT\}/g, NODE_PORT)
    .replace(/\$\{CADDY_HTTP_PORT\}/g, CADDY_HTTP_PORT)
    .replace(/\$\{XHTTP_UPSTREAM_PORT\}/g, XHTTP_UPSTREAM_PORT)
    .replace(/\$\{WS_UPSTREAM_PORT\}/g, WS_UPSTREAM_PORT)
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
    console.error(`${LOG_PREFIX} ERROR: reality-watcher.js requires config_path argument`);
    process.exit(1);
  }

  await waitForPort(INTERNAL_REST_PORT, 120000);

  let prevHash = '';
  let firstRun = true;

  while (true) {
    if (firstRun) {
      firstRun = false;
    } else {
      await new Promise((r) => setTimeout(r, REALITY_SPLIT_INTERVAL));
    }

    let configJson;
    try {
      const raw = await httpGet(`http://127.0.0.1:${INTERNAL_REST_PORT}/internal/get-config`);
      configJson = JSON.parse(raw);
    } catch {
      continue;
    }

    if (!configJson || Object.keys(configJson).length === 0) continue;

    const reality = extractRealityConfig(configJson);
    const realityPort = reality ? String(reality.port) : '';
    const realitySnis = reality ? reality.serverNames : '';

    const currentHash = hashString(`${realityPort}\n${realitySnis}`);
    if (currentHash === prevHash) continue;
    prevHash = currentHash;

    if (realitySnis && realityPort) {
      log(`REALITY split detected: snis=[${realitySnis}] port=${realityPort}`);
    } else {
      log('REALITY split cleared, reverting to default TLS routing');
    }

    fs.writeFileSync(configPath, generateCaddyConfig(realitySnis, realityPort));
    caddyFmt(configPath);

    if (caddyReload(configPath)) {
      log('Caddy reloaded with updated REALITY split config');
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
