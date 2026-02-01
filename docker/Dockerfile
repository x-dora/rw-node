# 轻量版 Dockerfile - 使用 Go supervisord，无需 Python
# 构建阶段 - 只在 amd64 上构建（JS 代码跨平台）
FROM --platform=linux/amd64 node:24-alpine AS build
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
    && npm cache clean --force \
    # 清理 node_modules 中不必要的文件
    && find node_modules -type f \( \
        -name "*.md" -o -name "*.markdown" -o \
        -name "*.ts" -o -name "*.map" -o \
        -name "*.txt" -o -name "LICENSE*" -o \
        -name "*.yml" -o -name "*.yaml" -o \
        -name "Makefile" -o -name "*.mk" -o \
        -name "*.editorconfig" -o -name "*.npmignore" -o \
        -name "*.eslint*" -o -name "*.prettier*" -o \
        -name "CHANGELOG*" -o -name "HISTORY*" -o \
        -name "AUTHORS*" -o -name "CONTRIBUTORS*" \
    \) -delete 2>/dev/null || true \
    && find node_modules -type d \( \
        -name "test" -o -name "tests" -o \
        -name "example" -o -name "examples" -o \
        -name "doc" -o -name "docs" -o \
        -name ".github" -o -name "__tests__" \
    \) -exec rm -rf {} + 2>/dev/null || true


# 运行阶段
FROM node:24-alpine

ARG XRAY_CORE_VERSION=v25.12.8
ARG SUPERVISORD_VERSION=0.7.3
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/x-dora/rw-node"
LABEL org.opencontainers.image.description="Remnawave Node - Lightweight (No Python, Go Supervisord)"
LABEL org.opencontainers.image.licenses="AGPL-3.0"

WORKDIR /opt/app

# 复制构建产物（JS 代码跨平台，从 amd64 构建阶段复制）
COPY --from=build /opt/app/dist ./dist
COPY --from=build /opt/app/libs ./libs
COPY --from=build /opt/app/node_modules ./node_modules
COPY --from=build /opt/app/package*.json ./

# 安装运行时依赖 + supervisord + xray-core（合并为一层）
RUN set -ex; \
    apk add --no-cache bash curl; \
    mkdir -p /var/log/supervisor; \
    \
    # 安装 Go supervisord
    if [ "${TARGETARCH}" = "arm64" ]; then \
        ARCH_NAME="ARM64"; \
        XRAY_ARCH="arm64-v8a"; \
    else \
        ARCH_NAME="64-bit"; \
        XRAY_ARCH="64"; \
    fi; \
    curl -fsSL "https://github.com/ochinchina/supervisord/releases/download/v${SUPERVISORD_VERSION}/supervisord_${SUPERVISORD_VERSION}_Linux_${ARCH_NAME}.tar.gz" \
        | tar -xz -C /tmp; \
    mv /tmp/supervisord_${SUPERVISORD_VERSION}_Linux_${ARCH_NAME}/supervisord /usr/local/bin/; \
    chmod +x /usr/local/bin/supervisord; \
    \
    # 直接下载 Xray-core（比官方脚本更精简）
    XRAY_VER=$(echo ${XRAY_CORE_VERSION} | sed 's/^v//'); \
    curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_CORE_VERSION}/Xray-linux-${XRAY_ARCH}.zip" -o /tmp/xray.zip; \
    unzip -q /tmp/xray.zip -d /tmp/xray; \
    mv /tmp/xray/xray /usr/local/bin/xray; \
    chmod +x /usr/local/bin/xray; \
    mkdir -p /usr/local/share/xray; \
    mv /tmp/xray/geo*.dat /usr/local/share/xray/ 2>/dev/null || true; \
    ln -sf /usr/local/bin/xray /usr/local/bin/rw-core; \
    \
    # 创建辅助脚本
    printf '#!/bin/sh\ntail -n +1 -f /var/log/supervisor/xray.out.log\n' > /usr/local/bin/xlogs; \
    printf '#!/bin/sh\ntail -n +1 -f /var/log/supervisor/xray.err.log\n' > /usr/local/bin/xerrors; \
    chmod +x /usr/local/bin/xlogs /usr/local/bin/xerrors; \
    \
    # 清理（保留 curl 用于健康检查）
    rm -rf /tmp/* /var/cache/apk/*

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
