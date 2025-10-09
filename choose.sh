#!/bin/bash
# =============================================================================
# AFFiNE + n8n Installer (with Postgres for n8n)
# - User can choose: AFFiNE only, n8n only, or BOTH
# - Uses Docker (sudo docker ...) and Cloudflare Tunnel (cloudflared)
# - n8n runs with Postgres + Redis (self-hosted via docker compose)
# - Run as a normal user (do NOT run as root)
# =============================================================================

set -euo pipefail

# -------------------------
# Colors & small helpers
# -------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}================================${NC}\n"
}
print_success(){ echo -e "${GREEN}✓ $1${NC}"; }
print_error(){ echo -e "${RED}✗ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠ $1${NC}"; }
print_info(){ echo -e "${BLUE}ℹ $1${NC}"; }

# -------------------------
# Prevent running as root
# -------------------------
check_root() {
  if [ "$EUID" -eq 0 ]; then
    print_error "Do NOT run this script as root. Run as your normal user (this script uses sudo internally)."
    exit 1
  fi
}

check_root

# -------------------------
# USER INPUT
# -------------------------
print_header "AFFiNE + n8n Installer — Configuration"

read -r -p "🌐 Your domain (example.com): " DOMAIN
while [[ -z "${DOMAIN// }" ]]; do
  print_error "Domain cannot be empty."
  read -r -p "🌐 Your domain (example.com): " DOMAIN
done

# choose what to install
echo ""
echo "Choose installation option:"
echo "  1) AFFiNE only"
echo "  2) n8n only (with Postgres + Redis)"
echo "  3) Both AFFiNE + n8n (default)"
read -r -p "Select 1, 2 or 3 [3]: " INSTALL_CHOICE
INSTALL_CHOICE=${INSTALL_CHOICE:-3}

INSTALL_AFFINE=false
INSTALL_N8N=false
if [[ "$INSTALL_CHOICE" == "1" ]]; then
  INSTALL_AFFINE=true
elif [[ "$INSTALL_CHOICE" == "2" ]]; then
  INSTALL_N8N=true
else
  INSTALL_AFFINE=true
  INSTALL_N8N=true
fi

# Hostnames
if $INSTALL_AFFINE; then
  read -r -p "🔹 Subdomain for AFFiNE (default: affine): " SUBDOMAIN_AFFINE
  SUBDOMAIN_AFFINE=${SUBDOMAIN_AFFINE:-affine}
  FULL_DOMAIN_AFFINE="${SUBDOMAIN_AFFINE}.${DOMAIN}"
fi

if $INSTALL_N8N; then
  read -r -p "🔹 Subdomain for n8n (default: n8n): " SUBDOMAIN_N8N
  SUBDOMAIN_N8N=${SUBDOMAIN_N8N:-n8n}
  FULL_DOMAIN_N8N="${SUBDOMAIN_N8N}.${DOMAIN}"
fi

read -r -p "🕓 Timezone (default: Europe/Berlin): " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Berlin}

read -r -p "🔒 Cloudflare Tunnel name (default: multi-tunnel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-multi-tunnel}

# Installation directories (safe defaults under $HOME)
read -r -p "📁 AFFiNE directory (default: $HOME/affine): " AFFINE_DIR
AFFINE_DIR=${AFFINE_DIR:-$HOME/affine}

read -r -p "📁 n8n directory (default: $HOME/n8n): " N8N_DIR
N8N_DIR=${N8N_DIR:-$HOME/n8n}

# AFFiNE admin
if $INSTALL_AFFINE; then
  read -r -p "✉️ AFFiNE admin email (default: admin@${DOMAIN}): " AFFINE_ADMIN_EMAIL
  AFFINE_ADMIN_EMAIL=${AFFINE_ADMIN_EMAIL:-admin@"$DOMAIN"}
  # allow pre-set via environment variable AFFINE_ADMIN_PASSWORD otherwise default
  AFFINE_ADMIN_PASSWORD=${AFFINE_ADMIN_PASSWORD:-ChangeMe123!}
fi

# n8n basic auth (optional)
if $INSTALL_N8N; then
  read -r -p "🔑 Enable Basic Auth for n8n? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -r -p "n8n basic auth username: " N8N_BASIC_USER
    while [[ -z "${N8N_BASIC_USER// }" ]]; do
      print_error "Username cannot be empty."
      read -r -p "n8n basic auth username: " N8N_BASIC_USER
    done
    read -s -r -p "n8n basic auth password: " N8N_BASIC_PASSWORD
    echo
  else
    N8N_BASIC_USER=""
    N8N_BASIC_PASSWORD=""
  fi

  # n8n Postgres credentials (allow pre-set via env vars)
  N8N_PG_USER=${N8N_PG_USER:-n8n}
  N8N_PG_PASSWORD=${N8N_PG_PASSWORD:-n8n_pass}
  N8N_PG_DB=${N8N_PG_DB:-n8n}
fi

print_header "Summary"
echo -e "${BLUE}Domain: ${GREEN}$DOMAIN${NC}"
if $INSTALL_AFFINE; then
  echo -e "${BLUE}AFFiNE: ${GREEN}$FULL_DOMAIN_AFFINE${NC} -> Dir: ${AFFINE_DIR}"
fi
if $INSTALL_N8N; then
  echo -e "${BLUE}n8n: ${GREEN}$FULL_DOMAIN_N8N${NC} -> Dir: ${N8N_DIR}"
fi
echo -e "${BLUE}Tunnel name: ${GREEN}$TUNNEL_NAME${NC}"
echo -e "${BLUE}Timezone: ${GREEN}$TIMEZONE${NC}"
echo ""
read -r -p "Press Enter to continue or Ctrl+C to abort..." || true
echo ""

# -------------------------
# Helpers
# -------------------------
ensure_directory() {
  local d="$1"
  mkdir -p "$d" || { print_error "Failed to create $d"; exit 1; }
  # Best-effort chown to the invoking user so host-mounted volumes are writeable
  if ! sudo chown -R "$USER":"$USER" "$d" 2>/dev/null; then
    print_warning "Unable to chown $d (you may need to adjust permissions manually)."
  fi
}

# -------------------------
# Install dependencies
# -------------------------
install_dependencies() {
  print_header "Step 1 — Update system & install dependencies"
  sudo apt update
  sudo apt upgrade -y
  sudo apt install -y curl wget git nano apt-transport-https ca-certificates gnupg lsb-release
  print_success "System dependencies installed"
}

# -------------------------
# Install Docker (sudo usage)
# -------------------------
install_docker() {
  print_header "Step 2 — Install Docker & Docker Compose plugin (uses sudo docker ...)"
  if sudo docker --version >/dev/null 2>&1; then
    print_warning "Docker already available via sudo docker"
    sudo docker --version || true
    return
  fi

  print_info "Installing Docker (using official convenience script)..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh

  # Try to ensure docker compose plugin exists
  if ! sudo docker compose version >/dev/null 2>&1; then
    print_warning "sudo docker compose not found; attempting to install docker-compose-plugin"
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin || print_warning "Could not install docker-compose-plugin via apt - continuing"
  fi

  print_success "Docker install complete. This script will use 'sudo docker' for all docker commands."
  sudo docker --version || true
  echo ""
}

# -------------------------
# AFFiNE docker-compose
# -------------------------
setup_affine_docker() {
  if ! $INSTALL_AFFINE; then return; fi
  print_header "Step — AFFiNE: prepare docker-compose"
  ensure_directory "$AFFINE_DIR"
  ensure_directory "${AFFINE_DIR}/data/postgres"
  ensure_directory "${AFFINE_DIR}/data/redis"
  ensure_directory "${AFFINE_DIR}/data/config"
  ensure_directory "${AFFINE_DIR}/data/storage"

  cat > "${AFFINE_DIR}/docker-compose.yml" <<EOF
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
    command: >
      sh -c "node ./scripts/self-host-predeploy && node ./dist/index.js"
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

  print_success "AFFiNE docker-compose written to: ${AFFINE_DIR}/docker-compose.yml"
  echo ""
}

# -------------------------
# n8n docker-compose (with Postgres + Redis)
# -------------------------
setup_n8n_docker() {
  if ! $INSTALL_N8N; then return; fi
  print_header "Step — n8n: prepare docker-compose (Postgres + Redis)"
  ensure_directory "$N8N_DIR"
  ensure_directory "${N8N_DIR}/data"
  ensure_directory "${N8N_DIR}/data/postgres"
  ensure_directory "${N8N_DIR}/data/redis"
  ensure_directory "${N8N_DIR}/.n8n"

  # Basic auth env block
  if [[ -n "${N8N_BASIC_USER:-}" ]]; then
    BASIC_ENV="
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_PASSWORD}"
  else
    BASIC_ENV=""
  fi

  cat > "${N8N_DIR}/docker-compose.yml" <<EOF
version: "3.8"

services:
  postgres:
    image: postgres:16
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${N8N_PG_USER}
      POSTGRES_PASSWORD: ${N8N_PG_PASSWORD}
      POSTGRES_DB: ${N8N_PG_DB}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./data/postgres:/var/lib/postgresql/data

  redis:
    image: redis:7
    container_name: n8n_redis
    restart: unless-stopped
    volumes:
      - ./data/redis:/data

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - GENERIC_TIMEZONE=${TIMEZONE}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${N8N_PG_DB}
      - DB_POSTGRESDB_USER=${N8N_PG_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_PG_PASSWORD}
${BASIC_ENV}
    volumes:
      - ./data:/home/node/.n8n
EOF

  print_success "n8n docker-compose written to: ${N8N_DIR}/docker-compose.yml"
  echo ""
}

# -------------------------
# Start services (only those selected)
# -------------------------
start_services() {
  print_header "Step — Start selected Docker stacks (using sudo docker compose)"

  if $INSTALL_AFFINE; then
    print_info "Starting AFFiNE stack..."
    cd "$AFFINE_DIR" || { print_error "Cannot cd to $AFFINE_DIR"; exit 1; }
    sudo docker compose pull || print_warning "Pull failed or images not available; continuing"
    sudo docker compose up -d --remove-orphans
    sleep 6
    if sudo docker ps --format '{{.Names}}' | grep -q '^affine_selfhosted$'; then
      print_success "AFFiNE started (affine_selfhosted)"
    else
      print_warning "AFFiNE container not detected running. Check logs with: (cd ${AFFINE_DIR} && sudo docker compose logs affine)"
    fi
    echo ""
  fi

  if $INSTALL_N8N; then
    print_info "Starting n8n stack..."
    cd "$N8N_DIR" || { print_error "Cannot cd to $N8N_DIR"; exit 1; }
    sudo docker compose pull || print_warning "Pull failed or images not available; continuing"
    sudo docker compose up -d --remove-orphans
    sleep 6
    if sudo docker ps --format '{{.Names}}' | grep -q '^n8n$'; then
      print_success "n8n started (n8n)"
    else
      print_warning "n8n container not detected running. Check logs with: (cd ${N8N_DIR} && sudo docker compose logs n8n)"
    fi
    echo ""
  fi
}

# -------------------------
# Install cloudflared
# -------------------------
install_cloudflared() {
  print_header "Step — Install cloudflared (Cloudflare Tunnel)"
  if command -v cloudflared >/dev/null 2>&1; then
    print_warning "cloudflared already installed"
    cloudflared --version || true
    return
  fi

  cd /tmp
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -O cloudflared-linux-arm64.deb || {
    print_error "Failed to download cloudflared. Check network and try again."
    exit 1
  }

  sudo dpkg -i cloudflared-linux-arm64.deb || {
    print_info "Attempting to fix missing deps..."
    sudo apt-get install -f -y
    sudo dpkg -i cloudflared-linux-arm64.deb || { print_error "Failed to install cloudflared"; exit 1; }
  }
  rm -f cloudflared-linux-arm64.deb
  print_success "cloudflared installed"
  echo ""
}

# -------------------------
# Authenticate cloudflared
# -------------------------
authenticate_cloudflare() {
  print_header "Step — Authenticate cloudflared with Cloudflare account"
  if [ -d "$HOME/.cloudflared" ] && ls "$HOME/.cloudflared"/*.json 1> /dev/null 2>&1; then
    print_warning "Found existing Cloudflare credentials in ~/.cloudflared/"
    read -r -p "Re-authenticate (y/N)? " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      print_info "Using existing credentials."
      echo ""
      return
    fi
  fi

  print_info "Running: cloudflared tunnel login (a browser will open or a URL will be printed)"
  cloudflared tunnel login
  print_success "Cloudflare authentication complete (credentials saved to ~/.cloudflared/ )"
  echo ""
}

# -------------------------
# Create or reuse tunnel
# -------------------------
create_tunnel() {
  print_header "Step — Create / Reuse Cloudflare Tunnel: ${TUNNEL_NAME}"
  # if exists reuse
  if cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
    print_warning "Tunnel ${TUNNEL_NAME} exists; reusing"
    TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
    print_info "Found tunnel id: ${TUNNEL_ID}"
    # check credentials file exists
    CRED_CHECK=$(find "$HOME" -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1 || true)
    if [ -z "$CRED_CHECK" ]; then
      print_warning "Credentials file for existing tunnel not found; recreating tunnel"
      cloudflared tunnel delete "$TUNNEL_NAME" || true
      cloudflared tunnel create "$TUNNEL_NAME"
      TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
    fi
  else
    cloudflared tunnel create "$TUNNEL_NAME"
    TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
    print_success "Tunnel created: ID=${TUNNEL_ID}"
  fi

  # Save tunnel ID into installed project dirs
  if $INSTALL_AFFINE; then echo "$TUNNEL_ID" > "${AFFINE_DIR}/.tunnel_id"; fi
  if $INSTALL_N8N;    then echo "$TUNNEL_ID" > "${N8N_DIR}/.tunnel_id";     fi
  print_info "Tunnel ID saved to project directories"
  echo ""
}

# -------------------------
# Configure cloudflared ingress
# -------------------------
configure_tunnel() {
  print_header "Step — Configure cloudflared ingress (multi-host)"

  # get tunnel id from one of the saved files
  TUNNEL_ID_FILE=""
  if $INSTALL_AFFINE && [ -f "${AFFINE_DIR}/.tunnel_id" ]; then TUNNEL_ID_FILE="${AFFINE_DIR}/.tunnel_id"; fi
  if [ -z "$TUNNEL_ID_FILE" ] && $INSTALL_N8N && [ -f "${N8N_DIR}/.tunnel_id" ]; then TUNNEL_ID_FILE="${N8N_DIR}/.tunnel_id"; fi
  if [ -z "$TUNNEL_ID_FILE" ]; then
    print_error "Tunnel ID not found in project directories. Aborting."
    exit 1
  fi
  TUNNEL_ID=$(cat "$TUNNEL_ID_FILE")

  sudo mkdir -p /etc/cloudflared

  # find credentials file in ~/.cloudflared
  CRED_SOURCE=$(find "$HOME" -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1 || true)
  if [ -z "$CRED_SOURCE" ]; then
    print_error "Could not find credentials file for tunnel ${TUNNEL_ID} under $HOME/.cloudflared"
    find "$HOME" -name "*.json" -path "*cloudflared*" 2>/dev/null || true
    exit 1
  fi

  sudo cp "$CRED_SOURCE" /etc/cloudflared/${TUNNEL_ID}.json
  CREDENTIALS_FILE="/etc/cloudflared/${TUNNEL_ID}.json"

  # Build ingress YAML dynamic block
  INGRESS_BLOCK=""
  if $INSTALL_AFFINE; then
    INGRESS_BLOCK="${INGRESS_BLOCK}  - hostname: ${FULL_DOMAIN_AFFINE}\n    service: http://localhost:3010\n"
  fi
  if $INSTALL_N8N; then
    INGRESS_BLOCK="${INGRESS_BLOCK}  - hostname: ${FULL_DOMAIN_N8N}\n    service: http://localhost:5678\n"
  fi

  sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDENTIALS_FILE}

ingress:
$(printf "%b" "${INGRESS_BLOCK}")  - service: http_status:404
EOF

  print_success "Wrote /etc/cloudflared/config.yml with ingress rules"
  echo ""
}

# -------------------------
# Create DNS records for installed hostnames
# -------------------------
create_dns_records() {
  print_header "Step — Create DNS records (Cloudflare) for hostnames"
  if $INSTALL_AFFINE; then
    print_info "Creating DNS record for ${FULL_DOMAIN_AFFINE}"
    if cloudflared tunnel route dns "$TUNNEL_NAME" "${FULL_DOMAIN_AFFINE}" 2>&1 | grep -q "already exists"; then
      print_warning "DNS record for ${FULL_DOMAIN_AFFINE} already exists"
    else
      print_success "DNS record created for ${FULL_DOMAIN_AFFINE}"
    fi
  fi

  if $INSTALL_N8N; then
    print_info "Creating DNS record for ${FULL_DOMAIN_N8N}"
    if cloudflared tunnel route dns "$TUNNEL_NAME" "${FULL_DOMAIN_N8N}" 2>&1 | grep -q "already exists"; then
      print_warning "DNS record for ${FULL_DOMAIN_N8N} already exists"
    else
      print_success "DNS record created for ${FULL_DOMAIN_N8N}"
    fi
  fi

  echo ""
  print_info "You can verify records in the Cloudflare dashboard (DNS section for the zone ${DOMAIN})"
  echo ""
}

# -------------------------
# Install cloudflared system service
# -------------------------
setup_tunnel_service() {
  print_header "Step — Install & enable cloudflared system service"
  print_info "Running: sudo cloudflared service install"
  sudo cloudflared service install || print_warning "service install may have failed if previously installed"
  sudo systemctl daemon-reload || true
  sudo systemctl enable --now cloudflared || true
  sleep 3
  if sudo systemctl is-active --quiet cloudflared; then
    print_success "cloudflared service is active"
  else
    print_warning "cloudflared service is not active. Check logs: sudo journalctl -u cloudflared -n 50 --no-pager"
  fi
  echo ""
}

# -------------------------
# Create backup scripts (for each installed service)
# -------------------------
create_backup_scripts() {
  print_header "Step — Create backup scripts"

  if $INSTALL_AFFINE; then
    cat > "$HOME/backup-affine.sh" <<EOF
#!/bin/bash
BACKUP_DIR=\$HOME/affine-backups
DATE=\$(date +%Y%m%d_%H%M%S)
mkdir -p "\$BACKUP_DIR"
tar -czf "\$BACKUP_DIR/affine-backup-\$DATE.tar.gz" "${AFFINE_DIR}/data"
# keep last 7
ls -t "\$BACKUP_DIR"/affine-backup-*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true
echo "AFFiNE backup completed: \$BACKUP_DIR/affine-backup-\$DATE.tar.gz"
EOF
    chmod +x "$HOME/backup-affine.sh"
    print_success "Created ~/backup-affine.sh"
  fi

  if $INSTALL_N8N; then
    cat > "$HOME/backup-n8n.sh" <<EOF
#!/bin/bash
BACKUP_DIR=\$HOME/n8n-backups
DATE=\$(date +%Y%m%d_%H%M%S)
mkdir -p "\$BACKUP_DIR"
tar -czf "\$BACKUP_DIR/n8n-backup-\$DATE.tar.gz" "${N8N_DIR}/data" "${N8N_DIR}/data/postgres"
# keep last 7
ls -t "\$BACKUP_DIR"/n8n-backup-*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true
echo "n8n backup completed: \$BACKUP_DIR/n8n-backup-\$DATE.tar.gz"
EOF
    chmod +x "$HOME/backup-n8n.sh"
    print_success "Created ~/backup-n8n.sh"
  fi

  echo ""
}

# -------------------------
# Final summary + useful commands
# -------------------------
print_summary() {
  print_header "Done — Summary & next steps"

  if $INSTALL_AFFINE; then
    echo -e "${GREEN}AFFiNE:${NC} ${FULL_DOMAIN_AFFINE}   (local: http://localhost:3010)"
    echo -e "  Dir: ${AFFINE_DIR}"
  fi
  if $INSTALL_N8N; then
    echo -e "${GREEN}n8n:${NC} ${FULL_DOMAIN_N8N}   (local: http://localhost:5678)"
    echo -e "  Dir: ${N8N_DIR}"
    echo -e "  DB: postgres (user: ${N8N_PG_USER}, db: ${N8N_PG_DB})"
  fi

  echo ""
  echo -e "${BLUE}Tunnel:${NC} ${TUNNEL_NAME}  ID: $(cat "${AFFINE_DIR}/.tunnel_id" 2>/dev/null || cat "${N8N_DIR}/.tunnel_id" 2>/dev/null || echo 'unknown')"
  echo ""
  echo -e "${BLUE}Useful commands:${NC}"
  if $INSTALL_AFFINE; then
    echo "  cd ${AFFINE_DIR} && sudo docker compose ps"
    echo "  cd ${AFFINE_DIR} && sudo docker compose logs -f affine"
  fi
  if $INSTALL_N8N; then
    echo "  cd ${N8N_DIR} && sudo docker compose ps"
    echo "  cd ${N8N_DIR} && sudo docker compose logs -f n8n"
  fi
  echo "  sudo systemctl status cloudflared"
  echo "  sudo journalctl -u cloudflared -f"
  if $INSTALL_AFFINE; then echo "  ~/backup-affine.sh"; fi
  if $INSTALL_N8N; then echo "  ~/backup-n8n.sh"; fi

  echo ""
  print_success "Installation & configuration finished. Visit the hostnames above after DNS is created/propagated."
  echo ""
  print_warning "IMPORTANT: Replace default passwords (AFFiNE admin and n8n/postgres passwords) in production."
  echo ""
}

# -------------------------
# Main flow
# -------------------------
main() {
  install_dependencies
  install_docker

  # Prepare compose files for chosen services
  setup_affine_docker
  setup_n8n_docker

  # Start selected services
  start_services

  # Cloudflare tunnel setup
  install_cloudflared
  authenticate_cloudflare
  create_tunnel
  configure_tunnel
  create_dns_records
  setup_tunnel_service

  # Backups and summary
  create_backup_scripts
  print_summary
}

main "$@"
