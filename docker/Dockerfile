# 轻量版 Dockerfile - 使用 Go supervisord，无需 Python
# 构建阶段
FROM node:22-alpine AS build
WORKDIR /opt/app
ARG UPSTREAM_REPO=remnawave/node
ARG VERSION=main

# 克隆源码并构建
RUN apk add --no-cache git \
    && git clone --depth 1 --branch ${VERSION} https://github.com/${UPSTREAM_REPO}.git . || \
       git clone --depth 1 https://github.com/${UPSTREAM_REPO}.git . \
    && npm ci --legacy-peer-deps \
    && npm run build \
    && npm ci --omit=dev --legacy-peer-deps \
    && npm cache clean --force


# 运行阶段
FROM node:22-alpine

ARG XRAY_CORE_VERSION=v25.12.8
ARG UPSTREAM_XRAY_REPO=XTLS
ARG XRAY_CORE_INSTALL_SCRIPT=https://raw.githubusercontent.com/remnawave/scripts/main/scripts/install-xray.sh
ARG SUPERVISORD_VERSION=0.7.3
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/x-dora/rw-node"
LABEL org.opencontainers.image.description="Remnawave Node - Lightweight (No Python, Go Supervisord)"
LABEL org.opencontainers.image.licenses="AGPL-3.0"

WORKDIR /opt/app

# 安装必要的包 + 创建日志目录
RUN apk add --no-cache bash curl unzip \
    && mkdir -p /var/log/supervisor

# 复制构建产物
COPY --from=build /opt/app/dist ./dist
COPY --from=build /opt/app/libs ./libs
COPY --from=build /opt/app/node_modules ./node_modules
COPY --from=build /opt/app/package*.json ./

# 安装 Go 版 supervisord + Xray-core + 辅助脚本
RUN set -ex; \
    # 安装 supervisord
    if [ "${TARGETARCH}" = "arm64" ]; then \
        ARCH_NAME="ARM64"; \
    else \
        ARCH_NAME="64-bit"; \
    fi; \
    curl -fsSL "https://github.com/ochinchina/supervisord/releases/download/v${SUPERVISORD_VERSION}/supervisord_${SUPERVISORD_VERSION}_Linux_${ARCH_NAME}.tar.gz" -o /tmp/supervisord.tar.gz; \
    cd /tmp && tar -xzf supervisord.tar.gz; \
    mv /tmp/supervisord_${SUPERVISORD_VERSION}_Linux_${ARCH_NAME}/supervisord /usr/local/bin/supervisord; \
    chmod +x /usr/local/bin/supervisord; \
    rm -rf /tmp/*; \
    # 安装 Xray-core
    curl -fsSL ${XRAY_CORE_INSTALL_SCRIPT} | bash -s -- ${XRAY_CORE_VERSION} ${UPSTREAM_XRAY_REPO}; \
    ln -sf /usr/local/bin/xray /usr/local/bin/rw-core; \
    # 创建辅助脚本
    echo '#!/bin/sh' > /usr/local/bin/xlogs; \
    echo 'tail -n +1 -f /var/log/supervisor/xray.out.log' >> /usr/local/bin/xlogs; \
    chmod +x /usr/local/bin/xlogs; \
    echo '#!/bin/sh' > /usr/local/bin/xerrors; \
    echo 'tail -n +1 -f /var/log/supervisor/xray.err.log' >> /usr/local/bin/xerrors; \
    chmod +x /usr/local/bin/xerrors

# 复制 entrypoint
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 环境变量
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-http-header-size=65536"
ENV XTLS_API_PORT=61000

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -fsk https://localhost:${NODE_PORT:-2222}/ || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "dist/src/main"]
