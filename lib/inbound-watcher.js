#!/usr/bin/env node
'use strict';

// 把 rw-node-go /internal/get-config 的响应解析成路由记录。
//
// 只做数据解析：不生成 Caddyfile、不写文件、不重载 Caddy。配置块生成、fmt 与热重载
// 统一由 lib/caddy.sh 的 render_inbound_routing / write_caddy_config 负责，避免每个
// 后端各维护一份模板替换逻辑。
//
// 用法：
//
//   curl -s "http://127.0.0.1:${INTERNAL_REST_PORT}/internal/get-config" \
//       | node inbound-watcher.js
//
// 记录格式与退出约定见 lib/inbound-watcher.py 顶部注释，三者输出必须完全一致。

const fs = require('fs');

// 可被 Caddy 按路径分流的网络类型，以及各类型下承载路径的配置字段
const PATH_SETTINGS = {
  ws: 'wsSettings',
  xhttp: 'xhttpSettings',
  httpupgrade: 'httpupgradeSettings',
};

function asStr(value) {
  return typeof value === 'string' ? value : '';
}

function asDict(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function validPort(value) {
  return Number.isInteger(value) && value > 0 && value < 65536 ? value : 0;
}

function normalizePath(path) {
  const raw = asStr(path);
  if (!raw) return '';
  let normalized = raw.split('?')[0].split('#')[0];
  if (normalized && !normalized.startsWith('/')) normalized = '/' + normalized;
  return normalized;
}

function httpPath(stream) {
  const settings = asDict(stream[PATH_SETTINGS[stream.network]]);
  return asStr(settings.path);
}

// 按 port 合并 REALITY 记录，并收集待分流的 HTTP 路径
function collect(config) {
  const inbounds = Array.isArray(config.inbounds) ? config.inbounds : [];
  const realityByPort = new Map();
  const httpCandidates = [];

  for (const rawInbound of inbounds) {
    const inbound = asDict(rawInbound);
    const stream = asDict(inbound.streamSettings);
    if (Object.keys(stream).length === 0) continue;

    if (stream.security === 'reality') {
      const port = validPort(inbound.port);
      const names = asDict(stream.realitySettings).serverNames;
      if (port && Array.isArray(names)) {
        const keys = names.filter((n) => typeof n === 'string');
        if (keys.length > 0) {
          const existing = realityByPort.get(port) || new Set();
          for (const key of keys) existing.add(key);
          realityByPort.set(port, existing);
        }
      }
      continue;
    }

    if (!(stream.network in PATH_SETTINGS)) continue;

    const path = normalizePath(httpPath(stream));
    const port = validPort(inbound.port);
    if (!path || !port) continue;

    httpCandidates.push({
      path,
      port,
      network: stream.network,
      tag: asStr(inbound.tag) || `port:${port}`,
    });
  }

  return { realityByPort, httpCandidates };
}

function render(config) {
  const panelSni = asStr(config.panelSni);
  const { realityByPort, httpCandidates } = collect(config);

  const byPath = new Map();
  for (const candidate of httpCandidates) {
    const entries = byPath.get(candidate.path) || [];
    entries.push(candidate);
    byPath.set(candidate.path, entries);
  }

  // 同一路径只能归属于一个端口，否则该路径无法确定转发目标，只报冲突不生成路由。
  const portsOf = (entries) => new Set(entries.map((e) => e.port));
  const httpRoutes = [...byPath.values()]
    .filter((entries) => portsOf(entries).size === 1)
    .map((entries) => entries[0])
    .sort((a, b) => (b.path.length - a.path.length) || (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));

  const records = [];
  if (panelSni) records.push(`panel\t${panelSni}`);

  for (const port of [...realityByPort.keys()].sort((a, b) => a - b)) {
    const names = [...realityByPort.get(port)].sort();
    records.push(`reality\t${port}\t${names.join(' ')}`);
  }

  for (const route of httpRoutes) {
    records.push(`http\t${route.path}\t${route.port}\t${route.network}`);
  }

  for (const path of [...byPath.keys()].sort()) {
    const entries = byPath.get(path);
    if (portsOf(entries).size > 1) {
      const tags = entries.map((e) => `${e.tag}(port:${e.port})`).join(', ');
      records.push(`conflict\t${path}\t${tags}`);
    }
  }

  return records;
}

function main() {
  let config;
  try {
    config = JSON.parse(fs.readFileSync(0, 'utf8'));
  } catch {
    return 1;
  }

  if (!config || typeof config !== 'object' || Array.isArray(config)) return 1;

  const records = render(config);
  if (records.length > 0) process.stdout.write(records.join('\n') + '\n');
  return 0;
}

process.exit(main());
