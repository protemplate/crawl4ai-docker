#!/bin/bash
set -e

# Build script for Crawl4AI Docker image
# Usage: ./scripts/build.sh [INSTALL_TYPE] [TAG] [PUSH] [PLATFORMS]

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
INSTALL_TYPE=${1:-all}
TAG=${2:-latest}
PUSH=${3:-false}
PLATFORMS=${4:-linux/amd64,linux/arm64}
DOCKER_USERNAME=${DOCKER_USERNAME:-protemplate}
GITHUB_BRANCH=${GITHUB_BRANCH:-main}
NO_CACHE=${NO_CACHE:-false}

# Validate install type
VALID_TYPES=("default" "all" "torch" "transformer")
if [[ ! " ${VALID_TYPES[@]} " =~ " ${INSTALL_TYPE} " ]]; then
    echo -e "${RED}Error: Invalid install type '${INSTALL_TYPE}'${NC}"
    echo "Valid types: ${VALID_TYPES[*]}"
    exit 1
fi

echo -e "${BLUE}🏗️  Building Crawl4AI Docker image...${NC}"
echo -e "${BLUE}📋 Configuration:${NC}"
echo -e "  • Install Type: ${YELLOW}$INSTALL_TYPE${NC}"
echo -e "  • Tag: ${YELLOW}$TAG${NC}"
echo -e "  • Push to Registry: ${YELLOW}$PUSH${NC}"
echo -e "  • Platforms: ${YELLOW}$PLATFORMS${NC}"
echo -e "  • GitHub Branch: ${YELLOW}$GITHUB_BRANCH${NC}"
echo -e "  • Docker Username: ${YELLOW}$DOCKER_USERNAME${NC}"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
fi

# Check if buildx is available
if ! docker buildx version > /dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Docker Buildx not found. Installing...${NC}"
    docker buildx create --use --name crawl4ai-builder
fi

# Prepare build arguments
BUILD_ARGS=(
    "--build-arg" "INSTALL_TYPE=$INSTALL_TYPE"
    "--build-arg" "GITHUB_BRANCH=$GITHUB_BRANCH"
)

# Add cache options
if [ "$NO_CACHE" = "true" ]; then
    BUILD_ARGS+=("--no-cache")
else
    BUILD_ARGS+=(
        "--cache-from" "type=gha"
        "--cache-from" "type=registry,ref=$DOCKER_USERNAME/crawl4ai:buildcache"
        "--cache-to" "type=gha,mode=max"
    )
fi

# Determine build command based on platforms
if [[ "$PLATFORMS" == *","* ]]; then
    # Multi-platform build
    echo -e "${BLUE}🔨 Building multi-platform image...${NC}"
    
    BUILD_CMD=(
        "docker" "buildx" "build"
        "--platform" "$PLATFORMS"
        "${BUILD_ARGS[@]}"
        "-t" "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE"
    )
    
    if [ "$PUSH" = "true" ]; then
        BUILD_CMD+=("--push")
        # Also push cache
        BUILD_CMD+=("--cache-to" "type=registry,ref=$DOCKER_USERNAME/crawl4ai:buildcache,mode=max")
    else
        BUILD_CMD+=("--load")
        echo -e "${YELLOW}Note: Multi-platform builds can only be loaded for the current platform when not pushing${NC}"
    fi
else
    # Single platform build
    echo -e "${BLUE}🔨 Building single-platform image...${NC}"
    
    BUILD_CMD=(
        "docker" "build"
        "${BUILD_ARGS[@]}"
        "-t" "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE"
    )
fi

# Add context
BUILD_CMD+=(".")

# Execute build
echo -e "${BLUE}Executing: ${BUILD_CMD[*]}${NC}"
if "${BUILD_CMD[@]}"; then
    echo -e "${GREEN}✅ Build completed successfully!${NC}"
else
    echo -e "${RED}❌ Build failed!${NC}"
    exit 1
fi

# If not pushing and single platform, test the image
if [ "$PUSH" != "true" ] && [[ "$PLATFORMS" != *","* ]]; then
    echo -e "${BLUE}🧪 Testing the built image...${NC}"
    
    # Test 1: Check if Crawl4AI can be imported
    echo -e "${BLUE}  • Testing Python import...${NC}"
    if docker run --rm "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE" python -c "import crawl4ai; print('✓ Crawl4AI imported successfully')"; then
        echo -e "${GREEN}    ✓ Import test passed${NC}"
    else
        echo -e "${RED}    ✗ Import test failed${NC}"
        exit 1
    fi
    
    # Test 2: Check if server can start
    echo -e "${BLUE}  • Testing server startup...${NC}"
    CONTAINER_ID=$(docker run -d -p 11235:11235 "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE")
    
    # Wait for server to be ready
    MAX_ATTEMPTS=30
    ATTEMPT=0
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        if curl -f -s http://localhost:11235/health > /dev/null 2>&1; then
            echo -e "${GREEN}    ✓ Server started successfully${NC}"
            break
        fi
        ATTEMPT=$((ATTEMPT + 1))
        sleep 2
    done
    
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo -e "${RED}    ✗ Server failed to start${NC}"
        docker logs $CONTAINER_ID
        docker stop $CONTAINER_ID > /dev/null 2>&1
        docker rm $CONTAINER_ID > /dev/null 2>&1
        exit 1
    fi
    
    # Clean up test container
    docker stop $CONTAINER_ID > /dev/null 2>&1
    docker rm $CONTAINER_ID > /dev/null 2>&1
fi

# Create additional tags if this is the latest build
if [ "$TAG" = "latest" ] && [ "$PUSH" = "true" ]; then
    echo -e "${BLUE}📦 Creating additional tags...${NC}"
    
    # Get Crawl4AI version
    CRAWL4AI_VERSION=$(docker run --rm "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE" python -c "import crawl4ai; print(getattr(crawl4ai, '__version__', '0.0.0'))" 2>/dev/null || echo "0.0.0")
    
    # Tag with version
    docker tag "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE" "$DOCKER_USERNAME/crawl4ai:$CRAWL4AI_VERSION-$INSTALL_TYPE"
    docker push "$DOCKER_USERNAME/crawl4ai:$CRAWL4AI_VERSION-$INSTALL_TYPE"
    
    # Tag with date
    DATE_TAG=$(date +%Y%m%d)
    docker tag "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE" "$DOCKER_USERNAME/crawl4ai:$DATE_TAG-$INSTALL_TYPE"
    docker push "$DOCKER_USERNAME/crawl4ai:$DATE_TAG-$INSTALL_TYPE"
    
    echo -e "${GREEN}✅ Additional tags created and pushed${NC}"
fi

# Summary
echo -e "${GREEN}✅ Build process completed!${NC}"
echo -e "${BLUE}📊 Summary:${NC}"
echo -e "  • Image: ${YELLOW}$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE${NC}"
echo -e "  • Size: ${YELLOW}$(docker images --format "{{.Size}}" "$DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE" | head -1)${NC}"

if [ "$PUSH" = "true" ]; then
    echo -e "  • Status: ${GREEN}Pushed to registry${NC}"
    echo -e "${BLUE}🐳 Pull command:${NC}"
    echo -e "  ${YELLOW}docker pull $DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE${NC}"
else
    echo -e "  • Status: ${YELLOW}Available locally${NC}"
    echo -e "${BLUE}🚀 Run command:${NC}"
    echo -e "  ${YELLOW}docker run -d -p 11235:11235 $DOCKER_USERNAME/crawl4ai:$TAG-$INSTALL_TYPE${NC}"
fi