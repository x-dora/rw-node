# Go implementation PaaS HTTPS direct Dockerfile.
# Downloads rw-node-go release assets and starts the Caddy Layer 4 front.

# Runs on the build platform and cross-compiles via GOOS/GOARCH, so the
# Caddy build never executes under QEMU emulation.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS caddy-builder

ARG CADDY_VERSION=latest
ARG TARGETARCH
ARG TARGETOS=linux

RUN apk add --no-cache git \
    && go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

# GOCACHE/GOMODCACHE build-cache mounts survive layer invalidation, so the
# Caddy build reuses compiled packages even when the layer cache is cold.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 \
    xcaddy build ${CADDY_VERSION} \
      --with github.com/mholt/caddy-l4 \
      --output /usr/bin/caddy

# geocheck binary for the node stats/get-geocheck route, matching the official
# node image layout (/usr/local/bin/geocheck).
FROM --platform=$BUILDPLATFORM alpine:3.24 AS geocheck

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

FROM alpine:3.24

ARG RW_NODE_GO_REPO=x-dora/rw-node-go
ARG RW_NODE_GO_VERSION=latest
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/x-dora/rw-node"
LABEL org.opencontainers.image.description="Remnawave Node Go Implementation - PaaS HTTPS Direct"
LABEL org.opencontainers.image.licenses="AGPL-3.0"

WORKDIR /opt/rw-node

COPY --from=caddy-builder /usr/bin/caddy /usr/local/bin/caddy
COPY --from=geocheck /usr/local/bin/geocheck /usr/local/bin/geocheck

RUN set -ex; \
    apk add --no-cache bash busybox-extras ca-certificates curl jq tar unzip; \
    if [ "${TARGETARCH}" = "arm64" ]; then \
        GO_ASSET="rw-node-go-linux-arm64-v8a.tar.gz"; \
    else \
        GO_ASSET="rw-node-go-linux-64.tar.gz"; \
    fi; \
    if [ "${RW_NODE_GO_VERSION}" = "latest" ]; then \
        RW_NODE_GO_VERSION="$(curl -fsSL "https://api.github.com/repos/${RW_NODE_GO_REPO}/releases/latest" | jq -r '.tag_name')"; \
    fi; \
    test -n "${RW_NODE_GO_VERSION}"; \
    curl -fsSL "https://github.com/${RW_NODE_GO_REPO}/releases/download/${RW_NODE_GO_VERSION}/${GO_ASSET}" -o /tmp/rw-node-go.tar.gz; \
    mkdir -p /tmp/rw-node-go /usr/local/share/xray /opt/rw-node/default-www; \
    tar -xzf /tmp/rw-node-go.tar.gz -C /tmp/rw-node-go; \
    install -m 755 /tmp/rw-node-go/rw-node-go /usr/local/bin/rw-node-go; \
    install -m 644 /tmp/rw-node-go/geoip.dat /usr/local/share/xray/geoip.dat; \
    install -m 644 /tmp/rw-node-go/geosite.dat /usr/local/share/xray/geosite.dat; \
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
