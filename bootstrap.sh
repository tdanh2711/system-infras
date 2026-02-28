#!/bin/sh
# =============================================================================
# SYSTEM-INFRAS BOOTSTRAP SCRIPT
# =============================================================================
# This script:
# 1. Reads project configuration from config/projects.json
# 2. Connects Caddy to project networks
# 3. Copies/creates project Caddyfiles with syslog config (routes to Seq)
# 4. Reloads Caddy configuration
#
# Usage: ./bootstrap.sh
# Safe to run multiple times (idempotent)
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"
PROJECTS_FILE="${CONFIG_DIR}/projects.json"
CADDY_PROJECTS_DIR="${SCRIPT_DIR}/caddy-projects"
CADDY_CONTAINER="system-caddy"
LOGGING_NETWORK="logging-net"

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# =============================================================================
# SEQ CONFIGURATION
# =============================================================================
SEQ_CONTAINER="system-seq"
SEQ_INTERNAL_URL="http://system-seq:80"
SEQ_SECRETS_FILE="${CONFIG_DIR}/seq-secrets.json"

# =============================================================================
# VECTOR CONFIGURATION
# =============================================================================
VECTOR_CONFIG_FILE="${CONFIG_DIR}/vector.generated.yaml"
VECTOR_CONTAINER="system-vector"

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
# JSON HELPER FUNCTIONS
# =============================================================================
# Read JSON value using jq or python3
json_read() {
    file="$1"
    query="$2"

    if command -v jq >/dev/null 2>&1; then
        jq -r "$query" "$file" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
import sys
with open('$file') as f:
    data = json.load(f)
query = '''$query'''
# Simple jq-like query parser
if query.startswith('.'):
    query = query[1:]
parts = query.replace('[', '.').replace(']', '').split('.')
result = data
for part in parts:
    if part == '':
        continue
    if part.isdigit():
        result = result[int(part)]
    elif ' | length' in part:
        key = part.replace(' | length', '')
        result = len(result[key]) if key else len(result)
    else:
        result = result.get(part, '')
print(result if result is not None else '')
" 2>/dev/null
    else
        echo ""
    fi
}

# Get project count from JSON
get_project_count() {
    if command -v jq >/dev/null 2>&1; then
        jq '.projects | length' "$PROJECTS_FILE" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; print(len(json.load(open('$PROJECTS_FILE'))['projects']))" 2>/dev/null
    else
        echo "0"
    fi
}

# Get project field by index
get_project_field() {
    index="$1"
    field="$2"

    if command -v jq >/dev/null 2>&1; then
        jq -r ".projects[$index].$field // empty" "$PROJECTS_FILE" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
with open('$PROJECTS_FILE') as f:
    projects = json.load(f)['projects']
if $index < len(projects):
    print(projects[$index].get('$field', ''))
" 2>/dev/null
    else
        echo ""
    fi
}

# Get setting value
get_setting() {
    query="$1"
    default="$2"

    result=$(json_read "$SETTINGS_FILE" "$query")
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "$default"
    else
        echo "$result"
    fi
}

# =============================================================================
# SYSLOG CONFIG GENERATION
# =============================================================================
# Generate HTTP log endpoint for a project (forwards to Vector -> Seq)
# Note: Caddy logs are collected by Vector from Docker containers automatically
# This endpoint is for applications that want to send structured logs directly
generate_syslog_config() {
    domain="$1"
    subdomain=$(get_setting ".caddy.logsSubdomain" "syslog")

    cat << EOF

# HTTP log endpoint for $domain (auto-generated by bootstrap.sh)
# Forwards structured logs to Vector -> Seq
# Usage: POST to https://${subdomain}.${domain}/ with JSON log body
${subdomain}.${domain} {
    import basic_auth

    # Forward to Seq HTTP source (port 80)
    reverse_proxy system-seq:80

    log {
        output file /data/logs/access-${domain}.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
EOF
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

    # Check JSON tool
    if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        log_error "Neither jq nor python3 is available"
        log_info "Install jq: apt install jq / brew install jq"
        exit 1
    fi

    # Check projects.json exists
    if [ ! -f "$PROJECTS_FILE" ]; then
        log_error "config/projects.json not found at: $PROJECTS_FILE"
        log_info "Run ./init.sh to create configuration"
        exit 1
    fi

    # Check settings.json exists
    if [ ! -f "$SETTINGS_FILE" ]; then
        log_error "config/settings.json not found at: $SETTINGS_FILE"
        log_info "Run ./init.sh to create configuration"
        exit 1
    fi

    log_success "Environment validated"
}

# =============================================================================
# SEQ SECURITY FUNCTIONS
# =============================================================================

wait_for_seq() {
    log_info "Waiting for Seq to be ready..."
    until curl -s "$SEQ_INTERNAL_URL" >/dev/null 2>&1; do
        sleep 2
    done
    log_success "Seq is ready"
}

seq_auth_enabled() {
    status=$(curl -s -o /dev/null -w "%{http_code}" "$SEQ_INTERNAL_URL/api/apikeys")
    if [ "$status" = "401" ]; then
        return 0   # auth enabled
    else
        return 1   # auth disabled
    fi
}

create_admin_api_key() {
    curl -s -X POST "$SEQ_INTERNAL_URL/api/apikeys" \
        -H "Content-Type: application/json" \
        -d '{
              "Title": "admin-key"
            }' | jq -r '.ApiKey'
}

create_project_api_key() {

    project="$1"
    admin_key="$2"

    curl -s -X POST "$SEQ_INTERNAL_URL/api/apikeys" \
        -H "Content-Type: application/json" \
        -H "X-Seq-ApiKey: $admin_key" \
        -d "{
              \"Title\": \"${project}-key\",
              \"Properties\": {
                \"project\": \"${project}\"
              }
            }" | jq -r '.ApiKey'
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================
load_configuration() {
    log_info "Loading configuration from JSON files..."

    PROJECT_COUNT=$(get_project_count)

    if [ -z "$PROJECT_COUNT" ] || [ "$PROJECT_COUNT" = "0" ]; then
        log_error "No projects found in config/projects.json"
        log_info "Run ./init.sh to configure projects"
        exit 1
    fi

    log_success "Loaded $PROJECT_COUNT project(s)"
}

bootstrap_seq_security() {

    log_info "Bootstrapping / Syncing Seq security..."

    wait_for_seq

    # -----------------------------
    # LOAD OR CREATE ADMIN KEY
    # -----------------------------
    if [ -f "$SEQ_SECRETS_FILE" ]; then
        admin_key=$(jq -r '.adminApiKey' "$SEQ_SECRETS_FILE")
        log_info "Loaded existing admin API key"
    else
        if seq_auth_enabled; then
            log_error "Seq already secured but no secrets file found."
            exit 1
        fi

        log_info "Fresh Seq detected. Creating admin key..."
        admin_key=$(create_admin_api_key)

        if [ -z "$admin_key" ] || [ "$admin_key" = "null" ]; then
            log_error "Failed to create admin key"
            exit 1
        fi

        echo "{ \"adminApiKey\": \"$admin_key\", \"projects\": {} }" > "$SEQ_SECRETS_FILE"
        chmod 600 "$SEQ_SECRETS_FILE"

        log_success "Admin key created and saved"
    fi

    # -----------------------------
    # GET EXISTING KEYS FROM SEQ
    # -----------------------------
    existing_keys=$(curl -s "$SEQ_INTERNAL_URL/api/apikeys" \
        -H "X-Seq-ApiKey: $admin_key")

    if echo "$existing_keys" | grep -q "Unauthorized"; then
        log_error "Admin API key invalid"
        exit 1
    fi

    # -----------------------------
    # SYNC PROJECT KEYS
    # -----------------------------
    i=0
    while [ $i -lt "$PROJECT_COUNT" ]; do

        network=$(get_project_field $i "network")
        project=$(echo "$network" | cut -d'-' -f1)

        stored_key=$(jq -r ".projects.$project // empty" "$SEQ_SECRETS_FILE")

        if [ -z "$stored_key" ]; then
            log_info "Creating API key for new project: $project"

            new_key=$(create_project_api_key "$project" "$admin_key")

            if [ -z "$new_key" ] || [ "$new_key" = "null" ]; then
                log_error "Failed to create API key for $project"
                exit 1
            fi

            tmp=$(mktemp)
            jq ".projects.$project = \"$new_key\"" \
                "$SEQ_SECRETS_FILE" > "$tmp" && mv "$tmp" "$SEQ_SECRETS_FILE"

            log_success "Created API key for $project"
        fi

        i=$((i + 1))
    done

    # -----------------------------
    # REMOVE KEYS FOR DELETED PROJECTS
    # -----------------------------
    for stored_project in $(jq -r '.projects | keys[]' "$SEQ_SECRETS_FILE"); do

        exists_in_config=false

        j=0
        while [ $j -lt "$PROJECT_COUNT" ]; do
            network=$(get_project_field $j "network")
            project=$(echo "$network" | cut -d'-' -f1)

            if [ "$stored_project" = "$project" ]; then
                exists_in_config=true
                break
            fi

            j=$((j + 1))
        done

        if [ "$exists_in_config" = false ]; then
            log_warn "Removing API key for deleted project: $stored_project"

            key_to_delete=$(jq -r ".projects.$stored_project" "$SEQ_SECRETS_FILE")

            curl -s -X DELETE "$SEQ_INTERNAL_URL/api/apikeys/$key_to_delete" \
                -H "X-Seq-ApiKey: $admin_key" >/dev/null 2>&1

            tmp=$(mktemp)
            jq "del(.projects.$stored_project)" \
                "$SEQ_SECRETS_FILE" > "$tmp" && mv "$tmp" "$SEQ_SECRETS_FILE"

            log_success "Removed API key for $stored_project"
        fi
    done

    log_success "Seq security sync complete"
}

generate_vector_config() {

    log_info "Generating Vector configuration..."

    admin_key=$(jq -r '.adminApiKey' "$SEQ_SECRETS_FILE")

    echo "data_dir: /var/lib/vector" > "$VECTOR_CONFIG_FILE"

    cat >> "$VECTOR_CONFIG_FILE" <<EOF

sources:
  docker_logs:
    type: docker_logs

transforms:

  enrich:
    type: remap
    inputs: [docker_logs]
    source: |
      parts = split(.container_name, "-")
      if length(parts) >= 2 {
        .project = parts[0]
        .service = join(slice(parts, 1, length(parts)), "-")
      }

  route_by_project:
    type: route
    inputs: [enrich]
    route:
EOF

    # Route section
    i=0
    while [ $i -lt "$PROJECT_COUNT" ]; do
        network=$(get_project_field $i "network")
        project=$(echo "$network" | cut -d'-' -f1)

        echo "      ${project}: '.project == \"${project}\"'" >> "$VECTOR_CONFIG_FILE"

        i=$((i + 1))
    done

    # Sink section
    echo "" >> "$VECTOR_CONFIG_FILE"
    echo "sinks:" >> "$VECTOR_CONFIG_FILE"

    for project in $(jq -r '.projects | keys[]' "$SEQ_SECRETS_FILE"); do

        key=$(jq -r ".projects.$project" "$SEQ_SECRETS_FILE")

        cat >> "$VECTOR_CONFIG_FILE" <<EOF

  seq_${project}:
    type: http
    inputs: [route_by_project.${project}]
    uri: "http://system-seq:80/ingest/clef"
    method: post
    request:
      headers:
        Content-Type: "application/vnd.serilog.clef"
        X-Seq-ApiKey: "${key}"
    encoding:
      codec: json
    framing:
      method: newline_delimited
    buffer:
      type: disk
      max_size: 5gb
      when_full: block
EOF

    done

    log_success "Vector config generated at $VECTOR_CONFIG_FILE"
}

reload_vector() {

    log_info "Reloading Vector..."

    if ! container_running "$VECTOR_CONTAINER"; then
        log_warn "Vector container not running"
        return
    fi

    docker restart "$VECTOR_CONTAINER"
    log_success "Vector restarted"
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

    # Connect to each project's network
    i=0
    while [ $i -lt "$PROJECT_COUNT" ]; do
        network=$(get_project_field $i "network")
        domain=$(get_project_field $i "domain")

        if [ -z "$network" ]; then
            i=$((i + 1))
            continue
        fi

        if ! network_exists "$network"; then
            log_warn "Network not found: $network (for $domain)"
            log_info "Make sure the project is running and network exists"
            i=$((i + 1))
            continue
        fi

        if container_connected_to_network "$CADDY_CONTAINER" "$network"; then
            log_success "Caddy connected to: $network"
        else
            log_info "Connecting Caddy to: $network"
            docker network connect "$network" "$CADDY_CONTAINER"
            log_success "Connected Caddy to: $network"
        fi

        i=$((i + 1))
    done
}

setup_project_caddyfiles() {
    log_info "Setting up project Caddyfiles..."

    # Create caddy-projects directory if it doesn't exist
    if [ ! -d "$CADDY_PROJECTS_DIR" ]; then
        mkdir -p "$CADDY_PROJECTS_DIR"
        log_success "Created directory: $CADDY_PROJECTS_DIR"
    fi

    i=0
    while [ $i -lt "$PROJECT_COUNT" ]; do
        domain=$(get_project_field $i "domain")
        network=$(get_project_field $i "network")
        caddyfile_src=$(get_project_field $i "caddyfile")
        dest_file="${CADDY_PROJECTS_DIR}/${domain}.caddy"

        if [ -z "$domain" ]; then
            i=$((i + 1))
            continue
        fi

        # Step 1: Check if dest file already has syslog config
        subdomain=$(get_setting ".caddy.logsSubdomain" "syslog")
        has_syslog=false
        if [ -f "$dest_file" ] && grep -q "${subdomain}\\.${domain}" "$dest_file" 2>/dev/null; then
            has_syslog=true
            log_info "Syslog config already exists for: $domain"
        fi

        # Step 2: Copy source caddyfile or create empty file (only if dest doesn't exist)
        if [ ! -f "$dest_file" ]; then
            if [ -n "$caddyfile_src" ] && [ -f "$caddyfile_src" ]; then
                cp "$caddyfile_src" "$dest_file"
                log_success "Copied: $caddyfile_src -> ${domain}.caddy"
            elif [ -n "$caddyfile_src" ]; then
                log_warn "Caddyfile not found: $caddyfile_src"
                : > "$dest_file"
                log_info "Created empty: ${domain}.caddy"
            else
                : > "$dest_file"
                log_info "Created empty: ${domain}.caddy (no source specified)"
            fi
        fi

        # Step 3: Append syslog config if not already present
        if [ "$has_syslog" = false ]; then
            generate_syslog_config "$domain" >> "$dest_file"
            log_success "Added syslog config for: ${subdomain}.$domain -> Seq"
        fi

        i=$((i + 1))
    done

    # Verify files in container
    if container_running "$CADDY_CONTAINER"; then
        log_info "Verifying files in container..."
        file_count=$(docker exec "$CADDY_CONTAINER" sh -c 'ls -1 /etc/caddy/projects/*.caddy 2>/dev/null | wc -l')
        file_count=$(echo "$file_count" | tr -d '[:space:]')
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
    subdomain=$(get_setting ".caddy.logsSubdomain" "syslog")

    echo ""
    echo "============================================================================="
    echo "                          BOOTSTRAP COMPLETE"
    echo "============================================================================="
    echo ""
    echo "Projects configured:"

    i=0
    while [ $i -lt "$PROJECT_COUNT" ]; do
        domain=$(get_project_field $i "domain")
        network=$(get_project_field $i "network")
        caddyfile=$(get_project_field $i "caddyfile")

        echo "  - $domain"
        echo "      Network: $network"
        echo "      Logs UI: ${subdomain}.$domain -> Seq"
        if [ -n "$caddyfile" ]; then
            echo "      Source:  $caddyfile"
        fi

        i=$((i + 1))
    done

    echo ""
    echo "Networks connected:"
    echo "  - $LOGGING_NETWORK (logging infrastructure)"

    i=0
    while [ $i -lt "$PROJECT_COUNT" ]; do
        network=$(get_project_field $i "network")
        if [ -n "$network" ]; then
            if network_exists "$network"; then
                echo "  - $network"
            else
                echo "  - $network (not found)"
            fi
        fi
        i=$((i + 1))
    done

    echo ""
    echo "Logging stack:"
    echo "  - Seq (log server): system-seq"
    echo "  - Vector (collector): system-vector"
    echo ""
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
    load_configuration
    bootstrap_seq_security
    generate_vector_config
    reload_vector
    create_logging_network
    connect_caddy_to_networks
    setup_project_caddyfiles
    reload_caddy
    show_summary
}

# Run main function
main "$@"
