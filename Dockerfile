# ==============================================================================
# GitNexus Gateway - Docker Image
# Packages gitnexus NPM package with HAProxy for API Key auth & CORS
# ==============================================================================

ARG BASE_IMAGE=node:22-trixie-slim
ARG GITNEXUS_VERSION=1.5.3

# ------------------------------------------------------------------------------
# Build the final image
# ------------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG GITNEXUS_VERSION

LABEL org.opencontainers.image.title="GitNexus Gateway"
LABEL org.opencontainers.image.description="Code intelligence gateway for GitNexus MCP with API Key auth and CORS"
LABEL org.opencontainers.image.source="https://github.com/abhigyanpatwari/GitNexus"
LABEL org.opencontainers.image.licenses="PolyForm-Noncommercial-1.0.0"

# Install runtime dependencies + build tools (for native modules), then clean up
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    # Runtime
    bash curl gosu netcat-openbsd openssl ca-certificates git tzdata procps haproxy \
    # Build tools (needed for native node modules, removed after install)
    python3 make g++ && \
    rm -rf /var/lib/apt/lists/*

# Install gitnexus, supergateway, then strip build tools in one layer
RUN echo "Installing gitnexus@${GITNEXUS_VERSION}..." && \
    npm install -g "gitnexus@${GITNEXUS_VERSION}" --omit=dev --no-audit --no-fund --loglevel error && \
    echo "Installing supergateway..." && \
    npm install -g supergateway@latest --omit=dev --no-audit --no-fund --loglevel error && \
    # Optimize: strip debug symbols from native modules
    find /usr/local/lib/node_modules -name '*.node' -exec strip --strip-debug {} + 2>/dev/null || true && \
    # Remove unnecessary files from node_modules
    find /usr/local/lib/node_modules \( \
        -name '*.md' -o -name '*.markdown' -o \
        -name '*.ts' -not -name '*.d.ts' -o \
        -name '*.map' -o \
        -name 'LICENSE*' -o -name 'CHANGELOG*' -o -name 'HISTORY*' -o \
        -name '.npmignore' -o -name '.eslintrc*' -o -name '.prettierrc*' -o \
        -name 'tsconfig.json' -o -name '.travis.yml' -o \
        -name 'Makefile' -o -name 'Gruntfile*' -o -name 'Gulpfile*' -o \
        -name '*.test.js' -o -name '*.spec.js' \
    \) -delete 2>/dev/null || true && \
    # Remove build tools
    apt-get purge -y python3 make g++ && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* \
           /usr/share/doc /usr/share/man /usr/share/info \
           /usr/share/locale /usr/share/lintian /var/log/*.log \
           /root/.npm /tmp/*

# Copy resource scripts
COPY resources/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh && \
    mkdir -p /etc/haproxy && \
    mv -f /usr/local/bin/haproxy.cfg.template /etc/haproxy/haproxy.cfg.template

# Create directories
RUN mkdir -p /data /state && chown node:node /data /state

# Default environment
ENV PORT=8010
ENV DATA_DIR=/data
ENV NODE_ENV=production

# Health check: analysis-aware
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
