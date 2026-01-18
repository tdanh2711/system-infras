#!/bin/sh
# =============================================================================
# SYSTEM-INFRAS BOOTSTRAP SCRIPT
# =============================================================================
# This script:
# 1. Connects Caddy to networks listed in caddy.env
# 2. Reloads Caddy configuration
#
# Usage: ./bootstrap.sh
# Safe to run multiple times (idempotent)
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CADDY_ENV_FILE="${SCRIPT_DIR}/caddy.env"
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

    # Check caddy.env exists
    if [ ! -f "$CADDY_ENV_FILE" ]; then
        log_error "caddy.env not found at: $CADDY_ENV_FILE"
        log_info "Copy caddy.env.example to caddy.env and configure your networks"
        exit 1
    fi

    log_success "Environment validated"
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================
load_caddy_env() {
    log_info "Loading configuration from: $CADDY_ENV_FILE"

    # Source the caddy env file
    . "$CADDY_ENV_FILE"

    if [ -z "$NETWORKS" ]; then
        log_error "NETWORKS variable is empty or not set in caddy.env"
        exit 1
    fi

    log_success "Networks to connect: $NETWORKS"

    if [ -n "$CADDY_FILES" ]; then
        log_success "Caddy files to copy: $CADDY_FILES"
    else
        log_info "No CADDY_FILES configured"
    fi
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

connect_caddy_to_networks() {
    log_info "Connecting Caddy to networks..."

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

    # Connect to each network listed in NETWORKS
    for network in $NETWORKS; do
        if ! network_exists "$network"; then
            log_warn "Network not found: $network"
            log_info "Make sure the project is running and network exists"
            continue
        fi

        if container_connected_to_network "$CADDY_CONTAINER" "$network"; then
            log_success "Caddy connected to: $network"
        else
            log_info "Connecting Caddy to: $network"
            docker network connect "$network" "$CADDY_CONTAINER"
            log_success "Connected Caddy to: $network"
        fi
    done
}

copy_caddy_files() {
    log_info "Copying Caddy configuration files..."

    CADDY_PROJECTS_DIR="${SCRIPT_DIR}/caddy-projects"

    # Create caddy-projects directory if it doesn't exist
    if [ ! -d "$CADDY_PROJECTS_DIR" ]; then
        mkdir -p "$CADDY_PROJECTS_DIR"
        log_success "Created directory: $CADDY_PROJECTS_DIR"
    fi

    # Skip if no files configured
    if [ -z "$CADDY_FILES" ]; then
        log_info "No Caddy files to copy"
        return 0
    fi

    # Copy each file (format: /path/to/file:destname)
    for entry in $CADDY_FILES; do
        # Parse path:name format
        file_path="${entry%%:*}"
        dest_name="${entry#*:}"

        # If no colon found, entry equals both parts - use filename as dest
        if [ "$file_path" = "$dest_name" ]; then
            log_error "Invalid format: $entry (expected /path/to/file:name)"
            log_info "Example: /root/project/Caddyfile.static:project.caddy"
            continue
        fi

        if [ ! -f "$file_path" ]; then
            log_warn "File not found: $file_path"
            continue
        fi

        # Ensure .caddy extension
        case "$dest_name" in
            *.caddy) ;;
            *) dest_name="${dest_name}.caddy" ;;
        esac

        dest_path="${CADDY_PROJECTS_DIR}/${dest_name}"

        # Copy the file
        if cp "$file_path" "$dest_path"; then
            log_success "Copied: $file_path -> $dest_name"
        else
            log_error "Failed to copy: $file_path"
        fi
    done

    # Verify files in container
    if container_running "$CADDY_CONTAINER"; then
        log_info "Verifying files in container..."
        file_count=$(docker exec "$CADDY_CONTAINER" ls -1 /etc/caddy/projects/*.caddy 2>/dev/null | wc -l || echo "0")
        if [ "$file_count" -gt 0 ]; then
            log_success "Found $file_count .caddy file(s) in container"
        else
            log_warn "No .caddy files found in container at /etc/caddy/projects/"
            log_info "Check if caddy-projects/ is mounted correctly in docker-compose.yml"
        fi
    fi
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
    for network in $NETWORKS; do
        if network_exists "$network"; then
            echo "  - $network"
        else
            echo "  - $network (not found)"
        fi
    done
    echo ""
    if [ -n "$CADDY_FILES" ]; then
        echo "Caddy files copied to caddy-projects/:"
        for entry in $CADDY_FILES; do
            file_path="${entry%%:*}"
            dest_name="${entry#*:}"
            case "$dest_name" in
                *.caddy) ;;
                *) dest_name="${dest_name}.caddy" ;;
            esac
            if [ -f "$file_path" ]; then
                echo "  - $dest_name (from $file_path)"
            else
                echo "  - $dest_name (source not found)"
            fi
        done
        echo ""
    fi
    echo "Caddy configuration has been reloaded."
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
    load_caddy_env
    create_logging_network
    connect_caddy_to_networks
    copy_caddy_files
    reload_caddy
    show_summary
}

# Run main function
main "$@"
