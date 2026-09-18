#!/usr/bin/env python3
"""把 rw-node-go /internal/get-config 的响应解析成路由记录。

只做数据解析：不生成 Caddyfile、不写文件、不重载 Caddy。配置块生成、fmt 与热重载
统一由 lib/caddy.sh 的 render_inbound_routing / write_caddy_config 负责，避免每个
后端各维护一份模板替换逻辑。

用法：

    curl -s "http://127.0.0.1:${INTERNAL_REST_PORT}/internal/get-config" \
        | python3 inbound-watcher.py

输出（字段以制表符分隔，顺序对所有后端一致）：

    panel<TAB><sni>
    reality<TAB><port><TAB><sni1> <sni2> ...
    http<TAB><path><TAB><port><TAB><network>
    conflict<TAB><path><TAB><tag(port:N)>, <tag(port:N)>

http 记录按路径长度倒序输出，让更具体的路径先匹配。没有可分流的 inbound 时不输出
任何内容（调用方退回默认兜底路由）；输入不是合法 JSON 时以非零状态退出，调用方跳过
本轮并保留上一份可用配置。

输出必须与 lib/inbound-watcher.js、lib/caddy.sh 的 parse_inbound_config_jq 完全一致。
"""

import json
import sys

# 可被 Caddy 按路径分流的网络类型
HTTP_NETWORKS = ("ws", "xhttp", "httpupgrade")

# 各网络类型下承载路径的配置字段
PATH_SETTINGS = {
    "ws": "wsSettings",
    "xhttp": "xhttpSettings",
    "httpupgrade": "httpupgradeSettings",
}


def as_str(value) -> str:
    return value if isinstance(value, str) else ""


def as_dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def valid_port(value):
    """返回可用的端口号，非数字或越界时返回 None。"""
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if 0 < value < 65536 else None


def normalize_path(path) -> str:
    path = as_str(path)
    if not path:
        return ""
    normalized = path.split("?")[0].split("#")[0]
    if normalized and not normalized.startswith("/"):
        normalized = "/" + normalized
    return normalized


def http_path(stream: dict) -> str:
    settings = as_dict(stream.get(PATH_SETTINGS.get(stream.get("network"), "")))
    return as_str(settings.get("path"))


def collect(config: dict) -> tuple:
    """按 port 合并 REALITY 记录，并收集待分流的 HTTP 路径。"""
    inbounds = config.get("inbounds")
    if not isinstance(inbounds, list):
        inbounds = []

    reality_by_port: dict = {}
    http_candidates: list = []

    for inbound in inbounds:
        inbound = as_dict(inbound)
        stream = as_dict(inbound.get("streamSettings"))
        if not stream:
            continue

        if stream.get("security") == "reality":
            port = valid_port(inbound.get("port"))
            names = as_dict(stream.get("realitySettings")).get("serverNames")
            if port and isinstance(names, list):
                keys = [n for n in names if isinstance(n, str)]
                if keys:
                    reality_by_port.setdefault(port, set()).update(keys)
            continue

        if stream.get("network") not in HTTP_NETWORKS:
            continue

        path = normalize_path(http_path(stream))
        port = valid_port(inbound.get("port"))
        if not path or not port:
            continue

        http_candidates.append({
            "path": path,
            "port": port,
            "network": stream.get("network"),
            "tag": as_str(inbound.get("tag")) or "port:%d" % port,
        })

    return reality_by_port, http_candidates


def render(config: dict) -> list:
    panel_sni = as_str(config.get("panelSni"))
    reality_by_port, http_candidates = collect(config)

    by_path: dict = {}
    for candidate in http_candidates:
        by_path.setdefault(candidate["path"], []).append(candidate)

    # 同一路径只能归属于一个端口，否则该路径无法确定转发目标，只报冲突不生成路由。
    http_routes = sorted(
        (entries[0] for entries in by_path.values()
         if len({e["port"] for e in entries}) == 1),
        key=lambda r: (-len(r["path"]), r["path"]),
    )

    records = []
    if panel_sni:
        records.append("panel\t%s" % panel_sni)

    for port in sorted(reality_by_port):
        records.append(
            "reality\t%d\t%s" % (port, " ".join(sorted(reality_by_port[port])))
        )

    for route in http_routes:
        records.append(
            "http\t%s\t%d\t%s" % (route["path"], route["port"], route["network"])
        )

    for path in sorted(by_path):
        entries = by_path[path]
        if len({e["port"] for e in entries}) > 1:
            tags = ", ".join("%s(port:%d)" % (e["tag"], e["port"]) for e in entries)
            records.append("conflict\t%s\t%s" % (path, tags))

    return records


def main() -> int:
    try:
        config = json.loads(sys.stdin.read())
    except (ValueError, TypeError):
        return 1

    if not isinstance(config, dict):
        return 1

    records = render(config)
    if records:
        sys.stdout.write("\n".join(records) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
