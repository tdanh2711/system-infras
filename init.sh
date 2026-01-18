#!/bin/sh
# =============================================================================
# SYSTEM-INFRAS INITIALIZATION SCRIPT
# =============================================================================
# This script MUST be run before `docker compose up -d`
#
# It will:
# 1. Check system requirements (Docker, permissions)
# 2. Create .env and caddy.env from templates
# 3. Generate secure passwords and bcrypt hashes
# 4. Create required directories with correct ownership
# 5. Validate configuration
#
# Usage: ./init.sh
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
CADDY_ENV_FILE="${SCRIPT_DIR}/caddy.env"
CADDY_ENV_EXAMPLE="${SCRIPT_DIR}/caddy.env.example"

# Directory ownership
GRAFANA_UID=472
LOKI_UID=10001

# Password length
PASSWORD_LENGTH=32

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
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

log_step() {
    printf "\n${CYAN}${BOLD}>>> %s${NC}\n" "$1"
}

prompt_yes_no() {
    question="$1"
    default="$2"

    if [ "$default" = "y" ]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi

    printf "${YELLOW}%s %s: ${NC}" "$question" "$prompt"
    read -r answer

    if [ -z "$answer" ]; then
        answer="$default"
    fi

    case "$answer" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_input() {
    question="$1"
    default="$2"

    # Print prompt to stderr so it shows when used in command substitution
    if [ -n "$default" ]; then
        printf "${YELLOW}%s [%s]: ${NC}" "$question" "$default" >&2
    else
        printf "${YELLOW}%s: ${NC}" "$question" >&2
    fi

    read -r answer

    if [ -z "$answer" ] && [ -n "$default" ]; then
        answer="$default"
    fi

    echo "$answer"
}

# Generate a random password
generate_password() {
    length="${1:-$PASSWORD_LENGTH}"
    # Use /dev/urandom for secure random generation
    # Filter to alphanumeric + some special chars, avoid problematic ones
    LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*_+-=' < /dev/urandom | head -c "$length" 2>/dev/null || \
    openssl rand -base64 "$length" 2>/dev/null | tr -dc 'A-Za-z0-9!@#%^*_+-=' | head -c "$length" || \
    date +%s%N | sha256sum | head -c "$length"
}

# Generate bcrypt hash using Docker
generate_bcrypt_hash() {
    password="$1"
    docker run --rm caddy:2-alpine caddy hash-password --plaintext "$password" 2>/dev/null
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================
check_docker() {
    log_step "Checking Docker"

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed"
        log_info "Install Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    log_success "Docker is installed"

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        log_info "Start Docker or check permissions"
        exit 1
    fi
    log_success "Docker daemon is running"

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose is not available"
        log_info "Install Docker Compose: https://docs.docker.com/compose/install/"
        exit 1
    fi
    log_success "Docker Compose is available"
}

check_sudo() {
    log_step "Checking Permissions"

    # Check if we can use sudo (needed for chown)
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            log_success "Sudo access available (passwordless)"
            SUDO_CMD="sudo"
        else
            log_warn "Sudo requires password - you may be prompted"
            SUDO_CMD="sudo"
        fi
    else
        if [ "$(id -u)" = "0" ]; then
            log_success "Running as root"
            SUDO_CMD=""
        else
            log_warn "Not running as root and sudo not available"
            log_warn "Directory ownership may not be set correctly"
            SUDO_CMD=""
        fi
    fi
}

# =============================================================================
# SETUP FUNCTIONS
# =============================================================================
setup_env_file() {
    log_step "Setting up .env file"

    if [ -f "$ENV_FILE" ]; then
        log_warn ".env file already exists"
        if prompt_yes_no "Overwrite existing .env file?" "n"; then
            log_info "Backing up existing .env to .env.backup"
            cp "$ENV_FILE" "${ENV_FILE}.backup"
        else
            log_info "Keeping existing .env file"
            return 0
        fi
    fi

    if [ ! -f "$ENV_EXAMPLE" ]; then
        log_error ".env.example not found"
        exit 1
    fi

    log_info "Generating secure passwords..."

    # Generate Grafana password
    GRAFANA_PASSWORD=$(generate_password)
    log_success "Generated Grafana admin password"

    # Generate Caddy basic auth password
    CADDY_PASSWORD=$(generate_password)
    log_success "Generated Caddy basic auth password"

    # Generate bcrypt hash for Caddy
    log_info "Generating bcrypt hash (this may take a moment)..."
    CADDY_HASH=$(generate_bcrypt_hash "$CADDY_PASSWORD")
    if [ -z "$CADDY_HASH" ]; then
        log_error "Failed to generate bcrypt hash"
        log_info "Make sure Docker can pull caddy:2-alpine"
        exit 1
    fi
    log_success "Generated bcrypt hash"

    # Get admin email for Caddy/Let's Encrypt
    echo ""
    ADMIN_EMAIL=$(prompt_input "Enter admin email for Let's Encrypt notifications" "admin@example.com")

    # Create .env file
    cat > "$ENV_FILE" << EOF
# =============================================================================
# SYSTEM-INFRAS ENVIRONMENT CONFIGURATION
# =============================================================================
# Generated by init.sh on $(date)
# NEVER commit this file to version control

# =============================================================================
# GRAFANA CONFIGURATION
# =============================================================================
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD='${GRAFANA_PASSWORD}'

# =============================================================================
# CADDY CONFIGURATION
# =============================================================================
# Username: admin
# Password: (saved below - SAVE THIS SOMEWHERE SAFE!)
CADDY_BASIC_AUTH_HASH='${CADDY_HASH}'

# Admin email for Let's Encrypt notifications
ADMIN_EMAIL=${ADMIN_EMAIL}

# =============================================================================
# LOGGING CONFIGURATION
# =============================================================================
LOKI_RETENTION_HOURS=336
EOF

    log_success "Created .env file"

    # Save passwords to a separate file for user reference
    CREDS_FILE="${SCRIPT_DIR}/.credentials"
    cat > "$CREDS_FILE" << EOF
# =============================================================================
# SYSTEM-INFRAS CREDENTIALS
# =============================================================================
# Generated on $(date)
#
# IMPORTANT: Save these credentials somewhere safe, then DELETE this file!
# This file should NOT be kept on the server long-term.
# =============================================================================

GRAFANA:
  Username: admin
  Password: ${GRAFANA_PASSWORD}

CADDY BASIC AUTH (for protected endpoints):
  Username: admin
  Password: ${CADDY_PASSWORD}

# =============================================================================
# After saving these credentials, delete this file:
#   rm ${CREDS_FILE}
# =============================================================================
EOF

    chmod 600 "$CREDS_FILE"
    log_success "Saved credentials to .credentials file"

    echo ""
    printf "${BOLD}${RED}==============================================================================${NC}\n"
    printf "${BOLD}${RED}                        IMPORTANT - SAVE THESE CREDENTIALS${NC}\n"
    printf "${BOLD}${RED}==============================================================================${NC}\n"
    echo ""
    printf "${BOLD}Grafana:${NC}\n"
    printf "  Username: admin\n"
    printf "  Password: ${CYAN}%s${NC}\n" "$GRAFANA_PASSWORD"
    echo ""
    printf "${BOLD}Caddy Basic Auth:${NC}\n"
    printf "  Username: admin\n"
    printf "  Password: ${CYAN}%s${NC}\n" "$CADDY_PASSWORD"
    echo ""
    printf "${YELLOW}Credentials also saved to: .credentials${NC}\n"
    printf "${YELLOW}DELETE .credentials after saving passwords elsewhere!${NC}\n"
    printf "${BOLD}${RED}==============================================================================${NC}\n"
    echo ""
}

setup_caddy_env() {
    log_step "Setting up caddy.env file"

    if [ -f "$CADDY_ENV_FILE" ]; then
        log_warn "caddy.env file already exists"
        if ! prompt_yes_no "Overwrite existing caddy.env file?" "n"; then
            log_info "Keeping existing caddy.env file"
            return 0
        fi
    fi

    if [ ! -f "$CADDY_ENV_EXAMPLE" ]; then
        log_error "caddy.env.example not found"
        exit 1
    fi

    echo ""
    log_info "Enter Docker network names that Caddy should connect to (space-separated)"
    log_info "Use exact network names as shown in 'docker network ls'"
    log_info "Example: lcdvn-network myproject-network"
    echo ""

    NETWORKS=$(prompt_input "Network names" "lcdvn-network")

    echo ""
    log_info "Enter paths to Caddyfile configs to copy (space-separated, or leave empty)"
    log_info "These files will be copied to caddy-projects/ on each bootstrap"
    log_info "Example: /root/project1/Caddyfile.static /root/project2/Caddyfile.static"
    echo ""

    CADDY_FILES=$(prompt_input "Caddyfile paths" "")

    cat > "$CADDY_ENV_FILE" << EOF
# =============================================================================
# CADDY CONFIGURATION
# =============================================================================
# Generated by init.sh on $(date)

NETWORKS="${NETWORKS}"

CADDY_FILES="${CADDY_FILES}"
EOF

    log_success "Created caddy.env file with networks: $NETWORKS"
    if [ -n "$CADDY_FILES" ]; then
        log_success "Caddy files configured: $CADDY_FILES"
    fi
}

setup_directories() {
    log_step "Creating directories"

    # Create Caddy directories
    mkdir -p "${SCRIPT_DIR}/caddy/data"
    mkdir -p "${SCRIPT_DIR}/caddy/config"
    log_success "Created caddy/data and caddy/config"

    # Create Grafana directory
    mkdir -p "${SCRIPT_DIR}/logging/grafana/data"
    log_success "Created logging/grafana/data"

    # Create Loki directory
    mkdir -p "${SCRIPT_DIR}/logging/loki/data"
    log_success "Created logging/loki/data"

    # Set ownership
    log_info "Setting directory ownership..."

    if [ -n "$SUDO_CMD" ]; then
        $SUDO_CMD chown -R ${GRAFANA_UID}:${GRAFANA_UID} "${SCRIPT_DIR}/logging/grafana/data"
        log_success "Set Grafana data ownership (UID ${GRAFANA_UID})"

        $SUDO_CMD chown -R ${LOKI_UID}:${LOKI_UID} "${SCRIPT_DIR}/logging/loki/data"
        log_success "Set Loki data ownership (UID ${LOKI_UID})"
    else
        log_warn "Could not set directory ownership - services may fail to start"
        log_info "Run manually:"
        log_info "  sudo chown -R ${GRAFANA_UID}:${GRAFANA_UID} logging/grafana/data"
        log_info "  sudo chown -R ${LOKI_UID}:${LOKI_UID} logging/loki/data"
    fi
}

validate_caddyfile() {
    log_step "Validating Caddyfile"

    CADDYFILE="${SCRIPT_DIR}/Caddyfile"

    if [ ! -f "$CADDYFILE" ]; then
        log_error "Caddyfile not found"
        exit 1
    fi

    log_success "Caddyfile found"
    log_info "Admin email will be loaded from ADMIN_EMAIL in .env"
}

validate_setup() {
    log_step "Validating setup"

    errors=0

    # Check .env exists and has required vars
    if [ ! -f "$ENV_FILE" ]; then
        log_error ".env file not found"
        errors=$((errors + 1))
    else
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        if [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
            log_error "GRAFANA_ADMIN_PASSWORD not set in .env"
            errors=$((errors + 1))
        fi
        if [ -z "$CADDY_BASIC_AUTH_HASH" ]; then
            log_error "CADDY_BASIC_AUTH_HASH not set in .env"
            errors=$((errors + 1))
        fi
    fi

    # Check caddy.env
    if [ ! -f "$CADDY_ENV_FILE" ]; then
        log_error "caddy.env file not found"
        errors=$((errors + 1))
    fi

    # Check directories
    if [ ! -d "${SCRIPT_DIR}/caddy/data" ]; then
        log_error "caddy/data directory not found"
        errors=$((errors + 1))
    fi

    if [ ! -d "${SCRIPT_DIR}/logging/grafana/data" ]; then
        log_error "logging/grafana/data directory not found"
        errors=$((errors + 1))
    fi

    if [ ! -d "${SCRIPT_DIR}/logging/loki/data" ]; then
        log_error "logging/loki/data directory not found"
        errors=$((errors + 1))
    fi

    # Check docker-compose.yml
    if [ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]; then
        log_error "docker-compose.yml not found"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        log_error "Validation failed with $errors error(s)"
        return 1
    fi

    log_success "All validations passed"
    return 0
}

show_next_steps() {
    echo ""
    printf "${BOLD}${GREEN}==============================================================================${NC}\n"
    printf "${BOLD}${GREEN}                        INITIALIZATION COMPLETE${NC}\n"
    printf "${BOLD}${GREEN}==============================================================================${NC}\n"
    echo ""
    printf "${BOLD}Next steps:${NC}\n"
    echo ""
    printf "  1. ${CYAN}Start services${NC}\n"
    printf "       docker compose up -d\n"
    echo ""
    printf "  2. ${CYAN}Run bootstrap${NC}\n"
    printf "       ./bootstrap.sh\n"
    printf "       (connects networks, copies Caddy configs, reloads Caddy)\n"
    echo ""
    printf "  3. ${CYAN}Verify health${NC}\n"
    printf "       docker compose ps\n"
    echo ""
    printf "  4. ${CYAN}Delete credentials file${NC}\n"
    printf "       rm .credentials\n"
    echo ""
    printf "${BOLD}${GREEN}==============================================================================${NC}\n"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    echo ""
    printf "${BOLD}${CYAN}==============================================================================${NC}\n"
    printf "${BOLD}${CYAN}                     SYSTEM-INFRAS INITIALIZATION${NC}\n"
    printf "${BOLD}${CYAN}==============================================================================${NC}\n"
    echo ""
    printf "This script will set up everything needed to run system-infras.\n"
    printf "It will generate secure passwords and create required directories.\n"
    echo ""

    if ! prompt_yes_no "Continue with initialization?" "y"; then
        log_info "Initialization cancelled"
        exit 0
    fi

    check_docker
    check_sudo
    setup_env_file
    setup_caddy_env
    setup_directories
    validate_caddyfile
    validate_setup
    show_next_steps
}

# Run main function
main "$@"
