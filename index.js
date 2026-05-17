#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PREFIX = '[node-starter]';
const ROOT_DIR = __dirname;
const START_SCRIPT = path.join(ROOT_DIR, 'start.sh');

if (!fs.existsSync(START_SCRIPT)) {
  console.error(`${PREFIX} ERROR: missing start script: ${START_SCRIPT}`);
  process.exit(1);
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
