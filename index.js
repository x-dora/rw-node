#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PREFIX = '[node-starter]';
const ROOT_DIR = __dirname;
const START_SCRIPT = path.join(ROOT_DIR, 'start.sh');
const INSTALL_DIR = path.join(ROOT_DIR, '.rw-node');

if (!fs.existsSync(START_SCRIPT)) {
  console.error(`${PREFIX} ERROR: missing start script: ${START_SCRIPT}`);
  process.exit(1);
}

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  for (const line of fs.readFileSync(filePath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let val = trimmed.slice(eq + 1).trim();
    if ((val[0] === '"' || val[0] === "'") && val[val.length - 1] === val[0]) {
      val = val.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = val;
  }
}

loadEnvFile(path.join(ROOT_DIR, '.env'));

if (!process.env.HTTP_FRONT_PORT) {
  process.env.HTTP_FRONT_PORT = process.env.PORT || '3000';
}
// 前置实现换成 rw-node-front 后，原来那组 CADDY_* 不再被任何东西读取。
if (!process.env.FRONT_SITE_DIR) {
  process.env.FRONT_SITE_DIR = path.join(INSTALL_DIR, 'www');
}

const child = spawn('bash', [START_SCRIPT], {
  cwd: ROOT_DIR,
  env: process.env,
  stdio: 'inherit',
});

let exiting = false;

function forwardSignal(signal) {
  if (exiting) return;
  if (!child.killed) {
    child.kill(signal);
  }
}

process.on('SIGINT', () => forwardSignal('SIGINT'));
process.on('SIGTERM', () => forwardSignal('SIGTERM'));

child.on('error', (error) => {
  console.error(`${PREFIX} ERROR: ${error.message}`);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  exiting = true;
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
