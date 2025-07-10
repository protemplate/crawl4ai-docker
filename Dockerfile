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
    && pip install --no-cache-dir \
        gunicorn \
        supervisor \
        redis \
        uvicorn[standard] \
        httpx \
        pydantic-settings \
        fastapi \
        python-multipart \
        aiofiles \
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

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
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

# Create startup script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Function to handle shutdown\n\
shutdown() {\n\
    echo "Shutting down Crawl4AI server..."\n\
    kill -SIGTERM "$SERVER_PID" 2>/dev/null || true\n\
    wait "$SERVER_PID" 2>/dev/null || true\n\
    exit 0\n\
}\n\
\n\
# Trap signals\n\
trap shutdown SIGTERM SIGINT\n\
\n\
# Debug information\n\
echo "Python version:"\n\
python --version\n\
echo "Installed packages:"\n\
pip list | grep -iE "(crawl|playwright|uvicorn|fastapi)" || echo "No matching packages found"\n\
echo "All packages (first 20):"\n\
pip list | head -20\n\
echo "Environment variables:"\n\
env | grep -E "(PATH|PYTHONPATH|APP_HOME)" | sort\n\
echo "Checking crawl4ai installation:"\n\
echo "App directory contents:"\n\
ls -la ${APP_HOME}/ | head -10\n\
echo "Trying to import crawl4ai:"\n\
python -c "try: import crawl4ai; print(\"SUCCESS: Crawl4ai imported\"); print(\"Version:\", getattr(crawl4ai, \"__version__\", \"unknown\"))\nexcept Exception as e: print(\"FAILED:\", str(e))"\n\
echo "Available crawl4ai modules:"\n\
python -c "try: import crawl4ai, pkgutil; print([name for _, name, _ in pkgutil.iter_modules(crawl4ai.__path__)])\nexcept Exception as e: print(\"FAILED:\", str(e))"\n\
\n\
# Start the server\n\
echo "Starting Crawl4AI server on port 11235..."\n\
# Try different ways to start the server\n\
if python -c "import crawl4ai.server" 2>/dev/null; then\n\
    echo "Using crawl4ai.server module"\n\
    python -m crawl4ai.server 2>&1 &\n\
elif python -c "import crawl4ai.api_server" 2>/dev/null; then\n\
    echo "Using crawl4ai.api_server module"\n\
    python -m crawl4ai.api_server 2>&1 &\n\
elif [ -f "${APP_HOME}/crawl4ai/server.py" ]; then\n\
    echo "Using server.py file directly"\n\
    cd ${APP_HOME} && python -m crawl4ai.server 2>&1 &\n\
elif [ -f "${APP_HOME}/deploy/docker/main.py" ]; then\n\
    echo "Using deploy/docker/main.py"\n\
    cd ${APP_HOME} && python deploy/docker/main.py 2>&1 &\n\
elif [ -f "${APP_HOME}/main.py" ]; then\n\
    echo "Using main.py in APP_HOME"\n\
    cd ${APP_HOME} && python main.py 2>&1 &\n\
elif which crawl4ai-server 2>/dev/null; then\n\
    echo "Using crawl4ai-server command"\n\
    crawl4ai-server 2>&1 &\n\
else\n\
    echo "ERROR: Could not find a way to start the Crawl4AI server"\n\
    echo "Directory contents:"\n\
    ls -la ${APP_HOME}/\n\
    echo "Crawl4ai module contents:"\n\
    ls -la ${APP_HOME}/crawl4ai/ 2>/dev/null || echo "No crawl4ai directory"\n\
    echo "Deploy directory contents:"\n\
    ls -la ${APP_HOME}/deploy/ 2>/dev/null || echo "No deploy directory"\n\
    exit 1\n\
fi\n\
SERVER_PID=$!\n\
\n\
# Wait for server to be ready\n\
echo "Waiting for server to be ready..."\n\
ATTEMPTS=0\n\
MAX_ATTEMPTS=120\n\
while ! curl -f -s http://localhost:11235/health > /dev/null; do\n\
    ATTEMPTS=$((ATTEMPTS + 1))\n\
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then\n\
        echo "Server failed to start after $MAX_ATTEMPTS attempts"\n\
        echo "Server process status:"\n\
        ps aux | grep -E "(python|crawl4ai)" || true\n\
        exit 1\n\
    fi\n\
    if [ $((ATTEMPTS % 10)) -eq 0 ]; then\n\
        echo "Still waiting... (attempt $ATTEMPTS/$MAX_ATTEMPTS)"\n\
    fi\n\
    sleep 1\n\
done\n\
echo "Server is ready after $ATTEMPTS seconds!"\n\
\n\
# Keep the script running\n\
wait "$SERVER_PID"\n\
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