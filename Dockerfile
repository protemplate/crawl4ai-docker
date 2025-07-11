# Multi-stage build for optimized Crawl4AI Docker image
# Stage 1: Dependencies builder
FROM python:3.11-slim-bookworm as builder

# Build arguments
ARG INSTALL_TYPE=all
ARG ENABLE_GPU=false
ARG GITHUB_REPO=https://github.com/unclecode/crawl4ai.git
ARG GITHUB_BRANCH=main

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create a virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Clone and install Crawl4AI
WORKDIR /tmp
RUN git clone --branch ${GITHUB_BRANCH} --depth 1 ${GITHUB_REPO} crawl4ai \
    && cd crawl4ai \
    && if [ "$INSTALL_TYPE" = "all" ]; then \
        # For 'all', install without GPU support to save space
        pip install --no-cache-dir -e ".[torch]" \
            --extra-index-url https://download.pytorch.org/whl/cpu; \
    elif [ "$INSTALL_TYPE" = "torch" ]; then \
        # CPU-only torch to save space
        pip install --no-cache-dir -e ".[torch]" \
            --extra-index-url https://download.pytorch.org/whl/cpu; \
    elif [ "$INSTALL_TYPE" = "transformer" ]; then \
        pip install --no-cache-dir -e ".[transformer]"; \
    else \
        pip install --no-cache-dir -e .; \
    fi \
    && pip install --no-cache-dir -r /tmp/crawl4ai/deploy/docker/requirements.txt \
    && pip install --no-cache-dir supervisor \
    && find /opt/venv -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true \
    && find /opt/venv -name "*.pyc" -delete 2>/dev/null || true

# Stage 2: Runtime image
FROM python:3.11-slim-bookworm

# Build arguments
ARG GITHUB_BRANCH=main

# Set environment variables
ENV APP_HOME=/app
ENV PYTHONPATH="${APP_HOME}:${PYTHONPATH}"
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/venv/bin:$PATH"

# Install runtime dependencies including Redis server
RUN apt-get update && apt-get install -y --no-install-recommends \
    redis-server \
    wget \
    gnupg \
    unzip \
    curl \
    git \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libatspi2.0-0 \
    libx11-6 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libxcb1 \
    libxkbcommon0 \
    libgtk-3-0 \
    libasound2 \
    fonts-liberation \
    libappindicator3-1 \
    libu2f-udev \
    libvulkan1 \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20.x (required for Playwright)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Create app directory and user
RUN useradd -m -u 1000 -s /bin/bash appuser
WORKDIR ${APP_HOME}

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv

# Copy Crawl4AI source code from builder
COPY --from=builder /tmp/crawl4ai ${APP_HOME}

# Check if deploy/docker/server exists and copy it to the right location
RUN if [ -d "${APP_HOME}/deploy/docker/server" ]; then \
        echo "Found server files in deploy/docker/server"; \
        cp -r ${APP_HOME}/deploy/docker/server/* ${APP_HOME}/crawl4ai/ 2>/dev/null || true; \
    fi \
    && if [ -f "${APP_HOME}/deploy/docker/main.py" ]; then \
        echo "Found main.py in deploy/docker"; \
        cp ${APP_HOME}/deploy/docker/main.py ${APP_HOME}/crawl4ai/server.py 2>/dev/null || true; \
    fi

# Install Playwright browsers with proper permissions
RUN npx --yes playwright@latest install chromium \
    && npx --yes playwright@latest install-deps chromium \
    && rm -rf /root/.npm /root/.cache \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p ${APP_HOME}/logs \
    && mkdir -p ${APP_HOME}/data \
    && mkdir -p ${APP_HOME}/cache \
    && mkdir -p ${APP_HOME}/.crawl4ai

# Copy custom configuration if it exists (will be overridden if mounted)
COPY config.yml ${APP_HOME}/config.yml

# Set ownership
RUN chown -R appuser:appuser ${APP_HOME} \
    && chown -R appuser:appuser /opt/venv

# Copy supervisord configuration
COPY deploy/docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create Redis data directory with correct permissions
RUN mkdir -p /var/lib/redis && chown -R appuser:appuser /var/lib/redis

# Create startup script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Debug information\n\
echo "Python version:"\n\
python --version\n\
echo "Checking crawl4ai installation:"\n\
python -c "try: import crawl4ai; print(\"SUCCESS: Crawl4ai imported\"); print(\"Version:\", getattr(crawl4ai, \"__version__\", \"unknown\"))\nexcept Exception as e: print(\"FAILED:\", str(e))"\n\
\n\
# Start supervisord to manage Redis and Gunicorn\n\
echo "Starting Crawl4AI services with supervisord..."\n\
exec /opt/venv/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf\n\
' > /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 11235

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:11235/health || exit 1

# Volume for persistent data
VOLUME ["${APP_HOME}/data", "${APP_HOME}/logs", "${APP_HOME}/cache"]

# Labels
LABEL maintainer="Your Name <your.email@example.com>"
LABEL org.opencontainers.image.title="Custom Crawl4AI"
LABEL org.opencontainers.image.description="Optimized Crawl4AI Docker image with latest updates"
LABEL org.opencontainers.image.url="https://github.com/protemplate/crawl4ai-docker"
LABEL org.opencontainers.image.source="https://github.com/protemplate/crawl4ai-docker"
LABEL org.opencontainers.image.documentation="https://github.com/protemplate/crawl4ai-docker/blob/main/README.md"

# Start the application
CMD ["/usr/local/bin/start.sh"]