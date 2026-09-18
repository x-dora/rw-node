# Go implementation PaaS HTTPS direct Dockerfile.
# Downloads rw-node-go and rw-node-front release assets and runs the front proxy,
# which multiplexes SSH / TLS / HTTP on the single exposed port.
#
# 这里不再有 Caddy 构建阶段：原先要用 xcaddy 从源码编 Caddy + layer4 插件，
# 每次构建多花几分钟，产出的二进制还有 48MB。前置分流现在由 rw-node-front
# 承担，直接从它的 release 下载。

# geocheck binary for the node stats/get-geocheck route, matching the official
# node image layout (/usr/local/bin/geocheck).
FROM --platform=$BUILDPLATFORM alpine:3.23 AS geocheck

ARG GEOCHECK_VERSION=0.3.0
ARG GEOCHECK_RELEASE_URL=https://github.com/remnawave/geocheck/releases/download
ARG TARGETARCH

RUN apk add --no-cache curl \
    && cd /tmp \
    && ARCHIVE="geocheck_linux_${TARGETARCH}.tar.gz" \
    && curl -fsSL -O "${GEOCHECK_RELEASE_URL}/v${GEOCHECK_VERSION}/${ARCHIVE}" \
    && curl -fsSL -O "${GEOCHECK_RELEASE_URL}/v${GEOCHECK_VERSION}/checksums.txt" \
    && grep "  ${ARCHIVE}\$" checksums.txt | sha256sum -c - \
    && tar -xzf "${ARCHIVE}" geocheck \
    && install -m 0755 geocheck /usr/local/bin/geocheck \
    && rm -rf /tmp/*

FROM alpine:3.23

ARG RW_NODE_GO_REPO=x-dora/rw-node-go
ARG RW_NODE_GO_VERSION=latest
ARG RW_NODE_FRONT_REPO=x-dora/rw-node-front
ARG RW_NODE_FRONT_VERSION=latest
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/x-dora/rw-node"
LABEL org.opencontainers.image.description="Remnawave Node Go Implementation - PaaS HTTPS Direct"
LABEL org.opencontainers.image.licenses="AGPL-3.0"

WORKDIR /opt/rw-node

COPY --from=geocheck /usr/local/bin/geocheck /usr/local/bin/geocheck

RUN set -ex; \
    apk add --no-cache bash busybox-extras ca-certificates curl jq tar unzip; \
    if [ "${TARGETARCH}" = "arm64" ]; then \
        GO_ASSET="rw-node-go-linux-arm64-v8a.tar.gz"; \
        FRONT_ASSET="rw-node-front-linux-arm64-v8a.tar.gz"; \
        SSHD_LITE_ARCH="arm64"; \
    else \
        GO_ASSET="rw-node-go-linux-64.tar.gz"; \
        FRONT_ASSET="rw-node-front-linux-64.tar.gz"; \
        SSHD_LITE_ARCH="amd64"; \
    fi; \
    mkdir -p /tmp/rw-node-go /tmp/rw-node-front /usr/local/share/xray /opt/rw-node/default-www; \
    if [ "${RW_NODE_GO_VERSION}" = "latest" ]; then \
        RW_NODE_GO_VERSION="$(curl -fsSL "https://api.github.com/repos/${RW_NODE_GO_REPO}/releases/latest" | jq -r '.tag_name')"; \
    fi; \
    test -n "${RW_NODE_GO_VERSION}"; \
    curl -fsSL "https://github.com/${RW_NODE_GO_REPO}/releases/download/${RW_NODE_GO_VERSION}/${GO_ASSET}" -o /tmp/rw-node-go.tar.gz; \
    tar -xzf /tmp/rw-node-go.tar.gz -C /tmp/rw-node-go; \
    install -m 755 /tmp/rw-node-go/rw-node-go /usr/local/bin/rw-node-go; \
    install -m 644 /tmp/rw-node-go/geoip.dat /usr/local/share/xray/geoip.dat; \
    install -m 644 /tmp/rw-node-go/geosite.dat /usr/local/share/xray/geosite.dat; \
    if [ "${RW_NODE_FRONT_VERSION}" = "latest" ]; then \
        RW_NODE_FRONT_VERSION="$(curl -fsSL "https://api.github.com/repos/${RW_NODE_FRONT_REPO}/releases/latest" | jq -r '.tag_name')"; \
    fi; \
    test -n "${RW_NODE_FRONT_VERSION}"; \
    curl -fsSL "https://github.com/${RW_NODE_FRONT_REPO}/releases/download/${RW_NODE_FRONT_VERSION}/${FRONT_ASSET}" -o /tmp/rw-node-front.tar.gz; \
    tar -xzf /tmp/rw-node-front.tar.gz -C /tmp/rw-node-front; \
    install -m 755 /tmp/rw-node-front/rw-node-front /usr/local/bin/rw-node-front; \
    if curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "https://github.com/AYJCSGM/mikutap/archive/master.zip" -o /tmp/default-www.zip \
        && unzip -q /tmp/default-www.zip -d /tmp/default-www \
        && index_file="$(find /tmp/default-www -mindepth 1 -maxdepth 4 -type f -iname index.html | sort | head -n 1)" \
        && [ -n "${index_file}" ]; then \
        site_dir="$(dirname "${index_file}")"; \
        cp -a "${site_dir}/." /opt/rw-node/default-www/; \
    else \
        printf '%s\n' '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head><body><main><h1>Welcome</h1><p>The service is running.</p></main></body></html>' > /opt/rw-node/default-www/index.html; \
    fi; \
    printf '%s\n' "${RW_NODE_GO_VERSION}" > /opt/rw-node/.rw-node-go-version; \
    printf '%s\n' "${RW_NODE_FRONT_VERSION}" > /opt/rw-node/.rw-node-front-version; \
    curl -fsSL "https://github.com/x-dora/sshd-lite/releases/latest/download/sshd-lite-linux-${SSHD_LITE_ARCH}" \
        -o /usr/local/bin/sshd-lite; \
    chmod 0755 /usr/local/bin/sshd-lite; \
    rm -rf /tmp/* /var/cache/apk/*

COPY docker-entrypoint.sh /usr/local/bin/
COPY lib/ /usr/local/lib/rw-node/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV REQUIRE_SECRET_KEY=true
ENV NODE_PORT=2222
ENV NODE_TLS_CLIENT_AUTH=mtls
ENV INTERNAL_REST_PORT=61001
ENV RW_NODE_DIR=/opt/rw-node
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV HTTP_FRONT_ENABLED=true
ENV XHTTP_UPSTREAM_PORT=8080
ENV WS_UPSTREAM_PORT=8880

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD bash -c 'if [[ "${HTTP_FRONT_ENABLED:-true}" == "true" ]]; then curl -sf --max-time 5 http://127.0.0.1:${HTTP_FRONT_PORT:-${PORT:-3000}}/health; elif [[ -n "${PORT:-}" ]]; then </dev/tcp/127.0.0.1/${PORT}; else </dev/tcp/127.0.0.1/${NODE_PORT:-2222}; fi' || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
