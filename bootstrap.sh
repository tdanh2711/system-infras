#!/bin/sh
# =============================================================================
# SYSTEM-INFRAS BOOTSTRAP SCRIPT
# =============================================================================
# This script:
# 1. Discovers project networks by prefix (e.g., projecta-backend, projecta-frontend)
# 2. Connects Caddy to all discovered project networks
# 3. Reloads Caddy configuration
#
# Usage: ./bootstrap.sh
# Safe to run multiple times (idempotent)
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_FILE="${SCRIPT_DIR}/projects.env"
CADDY_CONTAINER="system-caddy"
LOGGING_NETWORK="logging-net"

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[OK]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

# Check if a Docker network exists
network_exists() {
    docker network inspect "$1" >/dev/null 2>&1
}

# Check if a container is connected to a network
container_connected_to_network() {
    container="$1"
    network="$2"
    docker inspect "$container" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null | grep -q "$network"
}

# Check if a container exists and is running
container_running() {
    docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null | grep -q "true"
}

# =============================================================================
# VALIDATION
# =============================================================================
validate_environment() {
    log_info "Validating environment..."

    # Check Docker
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        exit 1
    fi

    # Check projects.env exists
    if [ ! -f "$PROJECTS_FILE" ]; then
        log_error "projects.env not found at: $PROJECTS_FILE"
        log_info "Copy projects.env.example to projects.env and configure your projects"
        exit 1
    fi

    log_success "Environment validated"
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================
load_projects() {
    log_info "Loading projects from: $PROJECTS_FILE"

    # Source the projects file
    . "$PROJECTS_FILE"

    if [ -z "$PROJECTS" ]; then
        log_error "PROJECTS variable is empty or not set in projects.env"
        exit 1
    fi

    log_success "Projects loaded: $PROJECTS"
}

create_logging_network() {
    log_info "Checking logging network: $LOGGING_NETWORK"

    if network_exists "$LOGGING_NETWORK"; then
        log_success "Logging network exists: $LOGGING_NETWORK"
    else
        log_info "Creating logging network: $LOGGING_NETWORK"
        docker network create "$LOGGING_NETWORK"
        log_success "Created logging network: $LOGGING_NETWORK"
    fi
}

# Find all networks with project prefix
find_project_networks() {
    project="$1"
    docker network ls --format '{{.Name}}' --filter "name=^${project}-"
}

connect_caddy_to_networks() {
    log_info "Connecting Caddy to project networks..."

    # Check if Caddy container exists
    if ! docker inspect "$CADDY_CONTAINER" >/dev/null 2>&1; then
        log_warn "Caddy container '$CADDY_CONTAINER' not found"
        log_info "Start the system with: docker compose up -d"
        log_info "Then run this script again"
        return 0
    fi

    # Check if Caddy is running
    if ! container_running "$CADDY_CONTAINER"; then
        log_warn "Caddy container is not running"
        log_info "Start with: docker compose up -d"
        return 0
    fi

    # Connect to logging network if not connected
    if container_connected_to_network "$CADDY_CONTAINER" "$LOGGING_NETWORK"; then
        log_success "Caddy connected to: $LOGGING_NETWORK"
    else
        log_info "Connecting Caddy to: $LOGGING_NETWORK"
        docker network connect "$LOGGING_NETWORK" "$CADDY_CONTAINER"
        log_success "Connected Caddy to: $LOGGING_NETWORK"
    fi

    # Connect to each project's networks (discovered by prefix)
    for project in $PROJECTS; do
        log_info "Finding networks for project: $project"

        networks=$(find_project_networks "$project")

        if [ -z "$networks" ]; then
            log_warn "No networks found with prefix: ${project}-"
            continue
        fi

        for network in $networks; do
            if container_connected_to_network "$CADDY_CONTAINER" "$network"; then
                log_success "Caddy connected to: $network"
            else
                log_info "Connecting Caddy to: $network"
                docker network connect "$network" "$CADDY_CONTAINER"
                log_success "Connected Caddy to: $network"
            fi
        done
    done
}

reload_caddy() {
    log_info "Reloading Caddy configuration..."

    if ! container_running "$CADDY_CONTAINER"; then
        log_warn "Caddy container is not running, skipping reload"
        return 0
    fi

    if docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile; then
        log_success "Caddy configuration reloaded"
    else
        log_error "Failed to reload Caddy configuration"
        log_info "Check Caddyfile syntax with: docker exec $CADDY_CONTAINER caddy validate --config /etc/caddy/Caddyfile"
        return 1
    fi
}

show_summary() {
    echo ""
    echo "============================================================================="
    echo "                          BOOTSTRAP COMPLETE"
    echo "============================================================================="
    echo ""
    echo "Networks connected:"
    echo "  - $LOGGING_NETWORK (logging infrastructure)"
    for project in $PROJECTS; do
        networks=$(find_project_networks "$project")
        if [ -n "$networks" ]; then
            for network in $networks; do
                echo "  - $network"
            done
        else
            echo "  - (no networks found for $project)"
        fi
    done
    echo ""
    echo "Next steps:"
    echo "  1. Ensure .env is configured (copy from .env.example)"
    echo "  2. Start services: docker compose up -d"
    echo "  3. Access logs at: https://syslog.<project>.com"
    echo ""
    echo "For each project, ensure containers:"
    echo "  - Are named: <project>-<service> (e.g., projecta-backend)"
    echo "  - Have label: logging=true"
    echo "  - Are on a network with prefix: <project>-"
    echo ""
    echo "============================================================================="
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    echo ""
    echo "============================================================================="
    echo "                     SYSTEM-INFRAS BOOTSTRAP"
    echo "============================================================================="
    echo ""

    validate_environment
    load_projects
    create_logging_network
    connect_caddy_to_networks
    reload_caddy
    show_summary
}

# Run main function
main "$@"
