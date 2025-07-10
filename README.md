# Custom Crawl4AI Docker Build 🐳

[![Build and Push Crawl4AI Docker Image](https://github.com/protemplate/crawl4ai-docker/actions/workflows/docker-build.yml/badge.svg)](https://github.com/protemplate/crawl4ai-docker/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/protemplate/crawl4ai)](https://hub.docker.com/r/protemplate/crawl4ai)
[![Docker Image Size](https://img.shields.io/docker/image-size/protemplate/crawl4ai/latest)](https://hub.docker.com/r/protemplate/crawl4ai)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

This repository provides an automated, optimized Docker build for [Crawl4AI](https://github.com/unclecode/crawl4ai) with weekly updates, multi-architecture support, and enhanced features.

## 🎯 Features

- **🔄 Auto-updated**: Weekly builds automatically check for Crawl4AI updates
- **🏗️ Multi-architecture**: Supports both AMD64 and ARM64 platforms
- **📦 Multiple variants**: Choose between minimal (`default`) and full-featured (`all`) builds
- **⚡ Optimized**: Multi-stage builds with efficient caching
- **🔧 Customizable**: Easy configuration through environment variables
- **🐳 Production-ready**: Health checks, resource limits, and monitoring support
- **🔒 Secure**: Non-root user, security headers, and best practices

## 🚀 Quick Start

### Using Docker

```bash
# Pull and run the latest full-featured image
docker run -d -p 11235:11235 --name crawl4ai \
  --shm-size=2gb \
  protemplate/crawl4ai:latest-all

# With LLM API keys
docker run -d -p 11235:11235 --name crawl4ai \
  --shm-size=2gb \
  -e OPENAI_API_KEY=your-key-here \
  protemplate/crawl4ai:latest-all

# With custom configuration
docker run -d -p 11235:11235 --name crawl4ai \
  --shm-size=2gb \
  -v $(pwd)/config.yml:/app/config.yml:ro \
  --env-file .llm.env \
  protemplate/crawl4ai:latest-all
```

### Using Docker Compose

```bash
# Copy environment template
cp .llm.env.example .llm.env
# Edit .llm.env with your API keys

# Start the service
docker-compose up -d

# View logs
docker-compose logs -f

# Stop the service
docker-compose down
```

## 📦 Available Images

| Image Tag | Description | Size | Use Case |
|-----------|-------------|------|----------|
| `latest-all` | Latest build with all features | ~2.5GB | Production, full features |
| `latest-default` | Latest minimal build | ~1.5GB | Basic crawling, smaller footprint |
| `VERSION-all` | Specific version, all features | ~2.5GB | Version pinning |
| `VERSION-default` | Specific version, minimal | ~1.5GB | Version pinning, minimal |
| `YYYYMMDD-all` | Date-based tag | ~2.5GB | Reproducible builds |

## 🔧 Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OPENAI_API_KEY` | OpenAI API key for LLM features | - |
| `ANTHROPIC_API_KEY` | Anthropic Claude API key | - |
| `GROQ_API_KEY` | Groq API key | - |
| `CRAWL4AI_PORT` | Port to expose | 11235 |
| `LOG_LEVEL` | Logging level | INFO |
| `WORKERS` | Number of worker processes | 4 |
| `MEMORY_LIMIT` | Container memory limit | 4G |
| `CPU_LIMIT` | Container CPU limit | 2.0 |

### Custom Configuration

Mount your own `config.yml` to override default settings:

```yaml
# config.yml
app:
  title: "My Crawl4AI Instance"
  port: 11235
  workers: 8

crawler:
  default_timeout: 60.0
  max_concurrent_crawls: 20
  
rate_limiting:
  enabled: true
  default_limit: "100/minute"
```

## 🛠️ Building Locally

### Prerequisites

- Docker Desktop 20.10.0+ with BuildKit
- Git
- (Optional) Docker Hub account for pushing

### Build Commands

```bash
# Clone the repository
git clone https://github.com/protemplate/crawl4ai-docker.git
cd crawl4ai-docker

# Build with default settings (all features)
./scripts/build.sh

# Build minimal version
./scripts/build.sh default

# Build and push to registry
./scripts/build.sh all latest true

# Build specific platforms
PLATFORMS=linux/amd64 ./scripts/build.sh all latest false

# Force rebuild without cache
NO_CACHE=true ./scripts/build.sh
```

### Build Arguments

| Argument | Description | Options |
|----------|-------------|---------|
| `INSTALL_TYPE` | Installation type | `default`, `all`, `torch`, `transformer` |
| `GITHUB_BRANCH` | Crawl4AI branch to build | `main`, `develop`, etc. |
| `ENABLE_GPU` | Enable GPU support | `true`, `false` |

## 🏥 Health Checks

The container includes comprehensive health checks:

```bash
# Check container health
./scripts/health-check.sh

# Check specific container
./scripts/health-check.sh my-crawl4ai-container

# Verbose health check
VERBOSE=true ./scripts/health-check.sh
```

Health endpoints:
- `/health` - Basic health status
- `/ready` - Readiness check
- `/metrics` - Prometheus metrics
- `/playground` - Interactive UI

## 🔄 GitHub Actions Workflow

The repository includes an advanced GitHub Actions workflow that:

1. **Scheduled Builds**: Weekly at 2 AM UTC
2. **Manual Triggers**: Build on-demand with custom options
3. **Auto-detection**: Only rebuilds when Crawl4AI updates
4. **Multi-platform**: Builds for AMD64 and ARM64
5. **Caching**: Efficient layer caching for faster builds
6. **Testing**: Automated image testing after build
7. **Notifications**: Build status summaries

### Manual Workflow Trigger

```bash
# Trigger via GitHub CLI
gh workflow run docker-build.yml \
  -f crawl4ai_branch=develop \
  -f install_type=all \
  -f force_rebuild=true
```

## 📊 Monitoring and Observability

### Prometheus Metrics

The container exposes Prometheus metrics at `/metrics`:

```yaml
# docker-compose.yml (uncomment prometheus service)
prometheus:
  image: prom/prometheus:latest
  volumes:
    - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
  ports:
    - "9090:9090"
```

### Logging

Configure logging through environment variables:

```bash
# JSON logs
LOG_LEVEL=DEBUG LOG_FORMAT=json docker-compose up

# File logging
docker run -v $(pwd)/logs:/app/logs \
  -e LOG_OUTPUT=file \
  protemplate/crawl4ai:latest-all
```

## 🔒 Security

- Runs as non-root user (`appuser`)
- No new privileges flag set
- Configurable security headers
- API key authentication support
- Network isolation with custom bridge
- Resource limits enforced

## 🧪 Testing

```bash
# Run basic tests
docker run --rm protemplate/crawl4ai:latest-all \
  python -c "import crawl4ai; print(crawl4ai.__version__)"

# Test API endpoint
curl http://localhost:11235/health

# Run integration tests
docker-compose up -d
./scripts/health-check.sh
docker-compose exec crawl4ai pytest
```

## 📚 Examples

### Basic Web Crawling

```python
import requests

# Crawl a webpage
response = requests.post('http://localhost:11235/crawl', json={
    'url': 'https://example.com',
    'wait_for': 'networkidle',
    'screenshot': True
})

result = response.json()
print(result['content'][:500])
```

### With LLM Extraction

```python
# Extract structured data using LLM
response = requests.post('http://localhost:11235/crawl', json={
    'url': 'https://example.com/products',
    'extraction_prompt': 'Extract all product names and prices',
    'llm_provider': 'openai/gpt-4o-mini'
})
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

This Docker build configuration is MIT licensed. Crawl4AI itself is licensed under its own terms.

## 🔗 Links

- [Crawl4AI Repository](https://github.com/unclecode/crawl4ai)
- [Docker Hub](https://hub.docker.com/r/protemplate/crawl4ai)
- [Issue Tracker](https://github.com/protemplate/crawl4ai-docker/issues)

## 🙏 Acknowledgments

- [Crawl4AI](https://github.com/unclecode/crawl4ai) by unclecode
- Built with ❤️ by the community

---

**Note**: Remember to:
1. Replace `protemplate` with your actual Docker Hub username
2. Set up GitHub Secrets for automated builds
3. Customize configuration files as needed