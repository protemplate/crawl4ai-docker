#!/bin/bash

# Health check script for Crawl4AI Docker container
# Usage: ./scripts/health-check.sh [CONTAINER_NAME] [PORT] [MAX_RETRIES]

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CONTAINER_NAME=${1:-crawl4ai-custom}
PORT=${2:-11235}
MAX_RETRIES=${3:-30}
RETRY_INTERVAL=2
VERBOSE=${VERBOSE:-false}

# Function to print verbose logs
log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${BLUE}[DEBUG] $1${NC}"
    fi
}

# Function to check if container exists
check_container_exists() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}❌ Container '${CONTAINER_NAME}' does not exist${NC}"
        return 1
    fi
    return 0
}

# Function to check if container is running
check_container_running() {
    local status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    if [ "$status" != "running" ]; then
        echo -e "${RED}❌ Container '${CONTAINER_NAME}' is not running (status: $status)${NC}"
        return 1
    fi
    return 0
}

# Function to get container health status
get_container_health() {
    docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "none"
}

# Function to get container logs
show_container_logs() {
    echo -e "${YELLOW}📋 Recent container logs:${NC}"
    docker logs --tail 20 "$CONTAINER_NAME" 2>&1
}

# Function to check HTTP endpoint
check_http_endpoint() {
    local url="$1"
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" "$url" 2>/dev/null)
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ]; then
        return 0
    else
        log_verbose "HTTP request to $url returned code: $http_code"
        return 1
    fi
}

# Function to perform comprehensive health check
perform_health_check() {
    local checks_passed=0
    local total_checks=0
    
    # Check 1: Container health endpoint
    echo -e "${BLUE}🔍 Checking health endpoint...${NC}"
    total_checks=$((total_checks + 1))
    if check_http_endpoint "http://localhost:${PORT}/health"; then
        echo -e "${GREEN}  ✓ Health endpoint is responding${NC}"
        checks_passed=$((checks_passed + 1))
        
        # Parse health response if possible
        if command -v jq > /dev/null 2>&1; then
            local health_data=$(curl -s "http://localhost:${PORT}/health")
            local status=$(echo "$health_data" | jq -r '.status // empty' 2>/dev/null)
            if [ -n "$status" ]; then
                echo -e "${BLUE}    Status: ${YELLOW}$status${NC}"
            fi
        fi
    else
        echo -e "${RED}  ✗ Health endpoint is not responding${NC}"
    fi
    
    # Check 2: API readiness
    echo -e "${BLUE}🔍 Checking API readiness...${NC}"
    total_checks=$((total_checks + 1))
    if check_http_endpoint "http://localhost:${PORT}/ready"; then
        echo -e "${GREEN}  ✓ API is ready${NC}"
        checks_passed=$((checks_passed + 1))
    elif check_http_endpoint "http://localhost:${PORT}/"; then
        echo -e "${GREEN}  ✓ API root is accessible${NC}"
        checks_passed=$((checks_passed + 1))
    else
        echo -e "${YELLOW}  ⚠ Ready endpoint not available${NC}"
    fi
    
    # Check 3: Playground availability
    echo -e "${BLUE}🔍 Checking playground...${NC}"
    total_checks=$((total_checks + 1))
    if check_http_endpoint "http://localhost:${PORT}/playground"; then
        echo -e "${GREEN}  ✓ Playground is accessible${NC}"
        checks_passed=$((checks_passed + 1))
    else
        echo -e "${YELLOW}  ⚠ Playground is not available${NC}"
    fi
    
    # Check 4: Container resource usage
    echo -e "${BLUE}🔍 Checking container resources...${NC}"
    total_checks=$((total_checks + 1))
    local stats=$(docker stats --no-stream --format "{{json .}}" "$CONTAINER_NAME" 2>/dev/null)
    if [ -n "$stats" ]; then
        if command -v jq > /dev/null 2>&1; then
            local cpu=$(echo "$stats" | jq -r '.CPUPerc' | sed 's/%//')
            local memory=$(echo "$stats" | jq -r '.MemUsage' | cut -d' ' -f1)
            local mem_limit=$(echo "$stats" | jq -r '.MemUsage' | cut -d'/' -f2 | sed 's/ //g')
            echo -e "${GREEN}  ✓ Resource usage:${NC}"
            echo -e "    • CPU: ${YELLOW}${cpu}%${NC}"
            echo -e "    • Memory: ${YELLOW}${memory} / ${mem_limit}${NC}"
        else
            echo -e "${GREEN}  ✓ Container is using resources${NC}"
        fi
        checks_passed=$((checks_passed + 1))
    else
        echo -e "${RED}  ✗ Unable to get resource usage${NC}"
    fi
    
    # Summary
    echo -e "\n${BLUE}📊 Health Check Summary:${NC}"
    echo -e "  • Checks passed: ${YELLOW}${checks_passed}/${total_checks}${NC}"
    
    if [ $checks_passed -eq $total_checks ]; then
        return 0
    elif [ $checks_passed -gt 0 ]; then
        return 1
    else
        return 2
    fi
}

# Main execution
echo -e "${BLUE}🏥 Crawl4AI Container Health Check${NC}"
echo -e "${BLUE}📋 Configuration:${NC}"
echo -e "  • Container: ${YELLOW}$CONTAINER_NAME${NC}"
echo -e "  • Port: ${YELLOW}$PORT${NC}"
echo -e "  • Max retries: ${YELLOW}$MAX_RETRIES${NC}"

# Check if container exists
if ! check_container_exists; then
    exit 1
fi

# Check if container is running
if ! check_container_running; then
    echo -e "${YELLOW}🔄 Attempting to start container...${NC}"
    if docker start "$CONTAINER_NAME"; then
        echo -e "${GREEN}✓ Container started${NC}"
        sleep 5
    else
        echo -e "${RED}❌ Failed to start container${NC}"
        exit 1
    fi
fi

# Get Docker health status
DOCKER_HEALTH=$(get_container_health)
echo -e "${BLUE}🐳 Docker health status: ${YELLOW}$DOCKER_HEALTH${NC}"

# Wait for container to be ready
echo -e "${BLUE}⏳ Waiting for container to be ready...${NC}"
ATTEMPT=0
READY=false

while [ $ATTEMPT -lt $MAX_RETRIES ]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    # Show progress
    printf "\r  Attempt ${YELLOW}%2d/${MAX_RETRIES}${NC}..." $ATTEMPT
    
    # Check if basic health endpoint responds
    if check_http_endpoint "http://localhost:${PORT}/health" > /dev/null 2>&1; then
        READY=true
        printf "\r  ${GREEN}✓ Container is responding!${NC}\n"
        break
    fi
    
    # Check Docker health status
    DOCKER_HEALTH=$(get_container_health)
    if [ "$DOCKER_HEALTH" = "unhealthy" ]; then
        printf "\r  ${RED}✗ Container marked as unhealthy by Docker${NC}\n"
        show_container_logs
        exit 1
    fi
    
    log_verbose "Health check attempt $ATTEMPT failed, retrying..."
    sleep $RETRY_INTERVAL
done

if [ "$READY" != "true" ]; then
    printf "\r  ${RED}✗ Container failed to become ready after $MAX_RETRIES attempts${NC}\n"
    echo -e "${YELLOW}Showing container logs for debugging:${NC}"
    show_container_logs
    exit 1
fi

# Perform comprehensive health check
echo -e "\n${BLUE}🔬 Performing comprehensive health check...${NC}"
if perform_health_check; then
    echo -e "\n${GREEN}✅ Container is healthy and ready!${NC}"
    echo -e "${BLUE}🌐 Access points:${NC}"
    echo -e "  • API: ${YELLOW}http://localhost:${PORT}${NC}"
    echo -e "  • Health: ${YELLOW}http://localhost:${PORT}/health${NC}"
    echo -e "  • Playground: ${YELLOW}http://localhost:${PORT}/playground${NC}"
    echo -e "  • Metrics: ${YELLOW}http://localhost:${PORT}/metrics${NC}"
    exit 0
else
    echo -e "\n${YELLOW}⚠️  Container is partially healthy${NC}"
    echo -e "Some health checks failed, but the container is operational."
    exit 1
fi