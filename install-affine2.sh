#!/usr/bin/env bash
# n8n -> AFFiNE Automated Installation Script for Raspberry Pi 5
# AFFiNE only + Docker + Cloudflare Tunnel
# Version: 2025-10-09
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helpers
print_header() {
    echo -e "\n${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}\n"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }

# refuse running as root
check_root() {
    if [ "$EUID" -eq 0 ]; then 
        print_error "Please do NOT run this script as root or with sudo. Run it as a regular user."
        exit 1
    fi
}

# ======================================================
# USER INPUT / CONFIG
# ======================================================
print_header "AFFiNE Raspberry Pi Setup — Configuration"

echo ""
print_info "Please enter the following configuration details:"
echo ""

# Domain and subdomain
read -p "🌐 Your domain (e.g., example.com): " DOMAIN
while [[ -z "${DOMAIN// }" ]]; do
    print_error "Domain cannot be empty."
    read -p "🌐 Your domain (e.g., example.com): " DOMAIN
done

read -p "🔹 Subdomain for AFFiNE (e.g., affine): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-affine}
FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

# Timezone
read -p "🕓 Timezone (default: Europe/Berlin): " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Berlin}

# Cloudflare Tunnel name
read -p "🔒 Cloudflare Tunnel name (default: affine-tunnel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-affine-tunnel}

# Installation directories (defaults under $HOME so no root paths)
read -p "📁 AFFiNE installation directory (default: $HOME/affine): " AFFINE_DIR
AFFINE_DIR=${AFFINE_DIR:-$HOME/affine}

# AFFiNE admin email and password (defaults)
read -p "✉️  AFFiNE admin email (default: admin@${DOMAIN}): " AFFINE_ADMIN_EMAIL
AFFINE_ADMIN_EMAIL=${AFFINE_ADMIN_EMAIL:-admin@${DOMAIN}}

# Allow override via environment var AFFINE_ADMIN_PASSWORD; otherwise default (change after install)
read -p "🔑 AFFiNE admin password (press Enter to use default or set AFFINE_ADMIN_PASSWORD env): " __TMP_PASS
if [ -n "${__TMP_PASS}" ]; then
    AFFINE_ADMIN_PASSWORD="$__TMP_PASS"
else
    AFFINE_ADMIN_PASSWORD=${AFFINE_ADMIN_PASSWORD:-ChangeMe123!}
fi
unset __TMP_PASS

print_header "Configuration Summary"
echo -e "${BLUE}Domain:         ${GREEN}$DOMAIN${NC}"
echo -e "${BLUE}Subdomain:      ${GREEN}$SUBDOMAIN${NC}"
echo -e "${BLUE}Full Domain:    ${GREEN}$FULL_DOMAIN${NC}"
echo -e "${BLUE}Tunnel Name:    ${GREEN}$TUNNEL_NAME${NC}"
echo -e "${BLUE}Timezone:       ${GREEN}$TIMEZONE${NC}"
echo -e "${BLUE}AFFiNE Dir:     ${GREEN}$AFFINE_DIR${NC}"
echo -e "${BLUE}Admin Email:    ${GREEN}$AFFINE_ADMIN_EMAIL${NC}"
echo -e "${BLUE}Admin Password: ${YELLOW}${AFFINE_ADMIN_PASSWORD}${NC}"
echo ""
read -p "Press Enter to confirm and continue, or Ctrl+C to cancel..."
echo ""

# ======================================================
# INSTALLATION STEPS (Functions)
# ======================================================

install_dependencies() {
    print_header "Step 1: Updating System and Installing Dependencies"
    print_info "This will update package lists and install required utilities."
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y curl wget git nano ca-certificates gnupg lsb-release
    print_success "System updated and dependencies installed"
    echo ""
}

install_docker() {
    print_header "Step 2: Installing Docker"
    if command -v docker &> /dev/null; then
        print_warning "Docker is already installed"
        docker --version || true
        echo ""
    else
        print_info "Installing Docker using get.docker.com..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh

        print_info "Adding current user ($USER) to docker group..."
        sudo usermod -aG docker "$USER" || print_warning "usermod failed — you may need to re-login for group changes to take effect."

        print_success "Docker installed successfully"
        docker --version || true
        echo ""
    fi

    # Ensure docker compose is available (Docker v2 includes it as 'docker compose')
    if ! docker compose version &> /dev/null; then
        print_warning "docker compose command not available as 'docker compose'. Trying 'docker-compose'."
        if command -v docker-compose &> /dev/null; then
            print_info "'docker-compose' found. Will use docker-compose command."
        else
            print_info "Installing docker-compose plugin..."
            # Try to install docker compose plugin using package if available
            sudo apt-get install -y docker-compose-plugin || print_warning "docker-compose-plugin unavailable via apt; continuing."
        fi
    fi
}

setup_affine_docker() {
    print_header "Step 3: Setting up AFFiNE with Docker Compose"

    if [ -z "$AFFINE_DIR" ]; then
        print_error "AFFINE_DIR is empty. Aborting."
        exit 1
    fi

    print_info "Creating AFFiNE directory: $AFFINE_DIR"
    mkdir -p "$AFFINE_DIR" || { print_error "Failed to create $AFFINE_DIR"; exit 1; }

    # Best-effort chown so Docker containers have writable host volumes
    if ! sudo chown -R "$USER":"$USER" "$AFFINE_DIR" 2>/dev/null; then
        print_warning "Could not chown $AFFINE_DIR (you may need sudo). Proceeding anyway."
    fi

    mkdir -p "$AFFINE_DIR/data/postgres" "$AFFINE_DIR/data/redis" "$AFFINE_DIR/data/config" "$AFFINE_DIR/data/storage"

    cd "$AFFINE_DIR" || { print_error "Cannot cd into $AFFINE_DIR"; exit 1; }

    print_info "Writing docker-compose.yml in: $AFFINE_DIR/docker-compose.yml"
    cat > docker-compose.yml <<EOF
version: "3.8"

services:
  postgres:
    image: postgres:16
    container_name: affine_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: affine
      POSTGRES_PASSWORD: affine
      POSTGRES_DB: affine
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./data/postgres:/var/lib/postgresql/data

  redis:
    image: redis:7
    container_name: affine_redis
    restart: unless-stopped
    volumes:
      - ./data/redis:/data

  affine:
    image: ghcr.io/toeverything/affine-graphql:stable
    container_name: affine_selfhosted
    depends_on:
      - postgres
      - redis
    ports:
      - "3010:3010"
    environment:
      - NODE_ENV=production
      - DATABASE_URL=postgres://affine:affine@postgres:5432/affine
      - REDIS_SERVER_HOST=redis
      - AFFINE_ADMIN_EMAIL=${AFFINE_ADMIN_EMAIL}
      - AFFINE_ADMIN_PASSWORD=${AFFINE_ADMIN_PASSWORD}
    volumes:
      - ./data/config:/root/.affine/config
      - ./data/storage:/root/.affine/storage
    restart: unless-stopped
EOF

    print_success "Docker Compose for AFFiNE created at: $AFFINE_DIR/docker-compose.yml"
    echo ""
}

start_affine() {
    print_header "Step 4: Starting AFFiNE"
    cd "$AFFINE_DIR" || { print_error "AFFiNE directory not found: $AFFINE_DIR"; exit 1; }

    print_info "Pulling images (if available)..."
    if ! sudo docker compose pull; then
        print_warning "sudo docker compose pull failed or not supported; continuing with existing / locally available images."
    fi

    print_info "Starting AFFiNE stack..."
    sudo docker compose up -d --remove-orphans

    print_info "Waiting for containers to initialize (10s)..."
    sleep 10

    if sudo docker ps --format '{{.Names}}' | grep -q '^affine_selfhosted$'; then
        print_success "AFFiNE container is running (affine_selfhosted)."
        print_info "Accessible locally at: http://localhost:3010"
    else
        print_error "AFFiNE failed to start. Showing quick diagnostics..."
        sudo docker compose ps || true
        sudo docker compose logs --no-color affine | tail -n 100 || true
        exit 1
    fi
    echo ""
}

install_cloudflared() {
    print_header "Step 5: Installing Cloudflare Tunnel (cloudflared)"
    if command -v cloudflared &> /dev/null; then
        print_warning "cloudflared is already installed"
        cloudflared --version || true
        echo ""
    else
        print_info "Downloading cloudflared for linux-arm64 (suitable for Raspberry Pi 5)..."
        cd /tmp
        # use latest release download URL for linux-arm64
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -O cloudflared-linux-arm64.deb
        print_info "Installing cloudflared package..."
        sudo dpkg -i cloudflared-linux-arm64.deb || { print_warning "dpkg install reported issues; attempting to fix with apt-get -f install"; sudo apt-get -f install -y; }
        rm -f cloudflared-linux-arm64.deb
        print_success "cloudflared installed successfully"
        cloudflared --version || true
        echo ""
    fi
}

authenticate_cloudflare() {
    print_header "Step 6: Authenticating with Cloudflare"
    print_info "You will be prompted to open a browser to authorize cloudflared with your Cloudflare account."
    echo ""

    if [ -d "$HOME/.cloudflared" ] && ls "$HOME/.cloudflared"/*.json 1> /dev/null 2>&1; then
        print_warning "Cloudflare credentials already exist in ~/.cloudflared/"
        print_info "Found existing authentication files"
        read -p "Do you want to re-authenticate? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping authentication, using existing credentials"
            echo ""
            return
        fi
    fi

    print_info "Running: cloudflared tunnel login"
    cloudflared tunnel login
    print_success "Cloudflare authentication completed"
    print_info "Credentials saved to: ~/.cloudflared/"
    echo ""
}

create_tunnel() {
    print_header "Step 7: Creating Cloudflare Tunnel"
    print_info "Tunnel name: ${TUNNEL_NAME}"
    echo ""

    # create or reuse tunnel
    if cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
        print_warning "Tunnel '$TUNNEL_NAME' already exists"
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        print_info "Existing tunnel ID: $TUNNEL_ID"
        # check credentials file presence
        CRED_CHECK=$(find "$HOME" -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1 || true)
        if [ -z "$CRED_CHECK" ]; then
            print_warning "Credentials file not found for existing tunnel; recreating tunnel..."
            cloudflared tunnel delete "$TUNNEL_NAME" || true
            cloudflared tunnel create "$TUNNEL_NAME"
            TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
            print_success "New tunnel created with ID: $TUNNEL_ID"
        else
            print_success "Using existing tunnel with credentials at: $CRED_CHECK"
        fi
    else
        print_info "Creating new tunnel: $TUNNEL_NAME"
        cloudflared tunnel create "$TUNNEL_NAME"
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        print_success "Tunnel created successfully!"
    fi

    # Save tunnel ID to AFFINE_DIR for later
    mkdir -p "$AFFINE_DIR"
    echo "$TUNNEL_ID" > "$AFFINE_DIR/.tunnel_id"
    print_info "Tunnel ID saved to: $AFFINE_DIR/.tunnel_id"
    echo ""
}

configure_tunnel() {
    print_header "Step 8: Configuring Cloudflare Tunnel"
    if [ ! -f "$AFFINE_DIR/.tunnel_id" ]; then
        print_error "Tunnel ID file not found at $AFFINE_DIR/.tunnel_id"
        exit 1
    fi
    TUNNEL_ID=$(cat "$AFFINE_DIR/.tunnel_id")

    print_info "Preparing /etc/cloudflared configuration and copying credentials for tunnel: $TUNNEL_ID"
    sudo mkdir -p /etc/cloudflared

    # locate credentials file in user's cloudflared dir
    CRED_SOURCE=$(find "$HOME" -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1 || true)
    if [ -z "$CRED_SOURCE" ]; then
        print_error "Could not find credentials file for tunnel ${TUNNEL_ID} in your home directory (~/.cloudflared)."
        print_info "List any found files:"
        find "$HOME" -name "*.json" -path "*cloudflared*" 2>/dev/null || true
        print_error "Installation cannot continue without the credentials file. Please ensure you completed 'cloudflared tunnel login' successfully."
        exit 1
    fi

    print_info "Copying credentials to /etc/cloudflared/${TUNNEL_ID}.json (requires sudo)"
    sudo cp "$CRED_SOURCE" "/etc/cloudflared/${TUNNEL_ID}.json"
    CREDENTIALS_FILE="/etc/cloudflared/${TUNNEL_ID}.json"

    print_info "Writing /etc/cloudflared/config.yml to forward ${FULL_DOMAIN} → localhost:3010"
    sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDENTIALS_FILE}

ingress:
  - hostname: ${FULL_DOMAIN}
    service: http://localhost:3010
  - service: http_status:404
EOF

    print_success "Tunnel configuration created at /etc/cloudflared/config.yml"
    echo ""
}

create_dns_record() {
    print_header "Step 9: Creating DNS Record"
    print_info "Running: cloudflared tunnel route dns $TUNNEL_NAME $FULL_DOMAIN"
    set +e
    # cloudflared will print message if record already exists; capture output
    OUT=$(cloudflared tunnel route dns "$TUNNEL_NAME" "$FULL_DOMAIN" 2>&1)
    RC=$?
    set -e
    if [ $RC -ne 0 ]; then
        if echo "$OUT" | grep -qi "already exists"; then
            print_warning "DNS record for ${FULL_DOMAIN} already exists (or was present)."
        else
            print_warning "cloudflared reported a non-zero exit code while creating DNS record. Output:"
            echo "$OUT"
        fi
    else
        print_success "DNS record created for ${FULL_DOMAIN}"
    fi

    print_info "You can verify this in your Cloudflare dashboard → DNS → Records (look for ${SUBDOMAIN} CNAME ...cfargotunnel.com)"
    echo ""
}

setup_tunnel_service() {
    print_header "Step 10: Setting up Cloudflare Tunnel Service"
    print_info "Installing cloudflared as a system service (requires sudo)"
    sudo cloudflared service install || { print_warning "cloudflared service install failed; attempting to enable service manually."; }

    print_info "Starting and enabling cloudflared service..."
    sudo systemctl daemon-reload || true
    sudo systemctl enable --now cloudflared || true

    sleep 3
    if sudo systemctl is-active --quiet cloudflared; then
        print_success "cloudflared service is running"
        sudo systemctl status cloudflared --no-pager | head -n 10 || true
    else
        print_error "cloudflared service is not active. Check logs with: sudo journalctl -u cloudflared -n 50 --no-pager"
        sudo journalctl -u cloudflared -n 50 --no-pager || true
        # Do not exit immediately here — user may still want to continue
    fi
    echo ""
}

create_backup_script() {
    print_header "Step 11: Creating Backup Script"

    cat > "$HOME/backup-affine.sh" <<'EOF'
#!/bin/bash
BACKUP_DIR=~/affine-backups
DATE=$(date +%Y%m%d_%H%M%S)
AFFINE_DIR="${AFFINE_DIR:-$HOME/affine}"

mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/affine-backup-$DATE.tar.gz" "$AFFINE_DIR/data" 2>/dev/null || { echo "Warning: could not archive $AFFINE_DIR/data"; exit 1; }

# Keep only last 7 backups
ls -t "$BACKUP_DIR"/affine-backup-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f 2>/dev/null

echo "Backup completed: $BACKUP_DIR/affine-backup-$DATE.tar.gz"
EOF

    # Ensure AFFINE_DIR is exported inside the script so it can be used
    # (replace placeholder AFFINE_DIR wherever used)
    sed -i "1s|^|AFFINE_DIR='${AFFINE_DIR}'\n|" "$HOME/backup-affine.sh"

    chmod +x "$HOME/backup-affine.sh"
    print_success "Backup script created at ~/backup-affine.sh"
    print_info "Run it anytime with: ~/backup-affine.sh"
    echo ""
}

print_summary() {
    print_header "Installation Complete! 🎉"

    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                      AFFiNE Installation Summary                     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BLUE}📍 Access Information:${NC}"
    echo -e "   ${GREEN}URL: https://${FULL_DOMAIN}${NC}"
    echo -e "   ${YELLOW}Note: DNS changes and Cloudflare may take a short moment to become active.${NC}"
    echo ""
    echo -e "${BLUE}📁 Installation Directories:${NC}"
    echo -e "   AFFiNE Data:      ${AFFINE_DIR}/data"
    echo -e "   Compose File:     ${AFFINE_DIR}/docker-compose.yml"
    echo -e "   Backups:          ~/affine-backups/"
    echo -e "   Tunnel Config:    /etc/cloudflared/config.yml"
    echo ""
    echo -e "${BLUE}🔧 Service Information:${NC}"
    echo -e "   Container:        affine_selfhosted (Docker)"
    echo -e "   Tunnel:           ${TUNNEL_NAME}"
    echo -e "   Tunnel ID:        $(cat "$AFFINE_DIR/.tunnel_id" 2>/dev/null || echo 'unknown')"
    echo ""
    echo -e "${BLUE}📝 First Steps:${NC}"
    echo -e "   1. Visit: ${GREEN}https://${FULL_DOMAIN}${NC}"
    echo -e "   2. Login with the admin email you provided: ${AFFINE_ADMIN_EMAIL}"
    echo -e "   3. Change the default admin password immediately if you used the default."
    echo ""
    echo -e "${BLUE}🔧 Useful Commands:${NC}"
    echo -e "   cd ${AFFINE_DIR} && docker compose ps"
    echo -e "   cd ${AFFINE_DIR} && docker compose logs -f affine"
    echo -e "   sudo systemctl status cloudflared"
    echo ""
    echo -e "${BLUE}🆘 Troubleshooting:${NC}"
    echo -e "   • If AFFiNE doesn't respond on ${FULL_DOMAIN}: check docker logs and cloudflared logs."
    echo -e "   • docker compose logs --no-color affine"
    echo -e "   • sudo journalctl -u cloudflared -f"
    echo ""
    print_success "Thank you! AFFiNE should now be available at https://${FULL_DOMAIN}"
    echo ""
}

# ======================================================
# MAIN
# ======================================================
main() {
    clear
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║                     AFFiNE Automated Installation                     ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    check_root

    install_dependencies
    install_docker
    setup_affine_docker
    start_affine
    install_cloudflared
    authenticate_cloudflare
    create_tunnel
    configure_tunnel
    create_dns_record
    setup_tunnel_service
    create_backup_script
    print_summary

    print_info "Note: If you were added to the docker group during this script, you may need to log out and log back in for the group membership to take effect."
    print_info "If you run into permission issues with Docker volumes, ensure the AFFiNE data directory is owned by your user."
    echo ""
}

main "$@"
