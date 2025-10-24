#!/bin/bash

# n8n Automated Installation Script for Raspberry Pi 5
# With Docker and Cloudflare Tunnel

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_header() {
    echo -e "\n${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}\n"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }

check_root() {
    if [ "$EUID" -eq 0 ]; then 
        print_error "Please do not run this script as root or with sudo"
        exit 1
    fi
}

# ======================================================
# USER INPUT SECTION
# ======================================================
print_header "n8n Raspberry Pi Setup — Configuration"

echo ""
print_info "Please enter the following configuration details:"
echo ""

read -p "🌐 Your domain (e.g., example.com): " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    print_error "Domain cannot be empty."
    read -p "🌐 Your domain (e.g., example.com): " DOMAIN
done

read -p "🔹 Subdomain for n8n (e.g., n8n): " SUBDOMAIN
SUBDOMAIN=${SUBDOMAIN:-n8n}

FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

read -p "🕓 Timezone (default: Europe/Berlin): " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Berlin}

read -p "🔒 Cloudflare Tunnel name (default: n8n-tunnel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-n8n-tunnel}

N8N_DIR="$HOME/n8n"

print_header "Configuration Summary"
echo -e "${BLUE}Domain:        ${GREEN}$DOMAIN${NC}"
echo -e "${BLUE}Subdomain:     ${GREEN}$SUBDOMAIN${NC}"
echo -e "${BLUE}Full Domain:   ${GREEN}$FULL_DOMAIN${NC}"
echo -e "${BLUE}Tunnel Name:   ${GREEN}$TUNNEL_NAME${NC}"
echo -e "${BLUE}Timezone:      ${GREEN}$TIMEZONE${NC}"
echo -e "${BLUE}n8n Directory: ${GREEN}$N8N_DIR${NC}"
echo ""
read -p "Press Enter to confirm and continue, or Ctrl+C to cancel..."
echo ""

# ======================================================
# CONTINUE WITH YOUR EXISTING FUNCTIONS BELOW
# ======================================================


check_root() {
    if [ "$EUID" -eq 0 ]; then 
        print_error "Please do not run this script as root or with sudo"
        exit 1
    fi
}

# Step 1: Update System
install_dependencies() {
    print_header "Step 1: Updating System and Installing Dependencies"
    
    print_info "This will update your system packages and install required dependencies"
    print_info "Dependencies: curl, wget, git, nano"
    echo ""
    
    print_info "Running: sudo apt update..."
    sudo apt update
    
    print_info "Running: sudo apt upgrade (this may take a few minutes)..."
    sudo apt upgrade -y
    
    print_info "Installing essential tools..."
    sudo apt install -y curl wget git nano
    
    print_success "System updated and dependencies installed"
    echo ""
}

# Step 2: Install Docker
install_docker() {
    print_header "Step 2: Installing Docker"
    
    print_info "Docker is a platform for running containerized applications"
    print_info "We'll use Docker to run n8n in an isolated, reproducible environment"
    echo ""
    
    if command -v docker &> /dev/null; then
        print_warning "Docker is already installed"
        docker --version
        echo ""
    else
        print_info "Downloading Docker installation script from get.docker.com..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        
        print_info "Installing Docker (this may take a few minutes)..."
        sudo sh get-docker.sh
        rm get-docker.sh
        
        print_info "Adding current user ($USER) to docker group..."
        print_info "This allows you to run docker commands without sudo"
        sudo usermod -aG docker $USER
        
        print_success "Docker installed successfully"
        docker --version
        echo ""
    fi
}

# Step 3: Create n8n Directory and Docker Compose
setup_n8n_docker() {
    print_header "Step 3: Setting up n8n with Docker Compose"
    
    print_info "n8n is a workflow automation tool that helps you connect different services"
    print_info "Creating directory structure at: $N8N_DIR"
    echo ""
    
    print_info "Creating directories..."
    mkdir -p "$N8N_DIR/data"
    cd "$N8N_DIR"
    print_success "Created: $N8N_DIR"
    print_success "Created: $N8N_DIR/data (this will store your workflows and credentials)"
    echo ""
    
    print_info "Creating docker-compose.yml configuration file..."
    print_info "Configuration details:"
    print_info "  - Domain: https://${FULL_DOMAIN}"
    print_info "  - Port: 5678 (local)"
    print_info "  - Timezone: ${TIMEZONE}"
    print_info "  - Data persistence: ./data volume"
    echo ""
    
    cat > docker-compose.yml <<EOF
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=${FULL_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${FULL_DOMAIN}/
      - GENERIC_TIMEZONE=${TIMEZONE}
      - N8N_EMAIL_MODE=smtp
      - N8N_METRICS=false
      - N8N_USER_MANAGEMENT_DISABLED=false
      - N8N_FILE_ACCESS_PATHS=/home/node/.n8n/backups
    volumes:
      - ./data:/home/node/.n8n
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
EOF
    
    print_success "Docker Compose configuration created at $N8N_DIR/docker-compose.yml"
    echo ""
}

# Step 4: Start n8n
start_n8n() {
    print_header "Step 4: Starting n8n"
    
    print_info "Starting n8n container with Docker Compose..."
    print_info "This will download the n8n Docker image if it's not already present"
    print_info "The image is approximately 500MB, so first run may take a few minutes"
    echo ""
    
    cd "$N8N_DIR"
    
    # Check if user has docker permissions
    if ! docker ps &>/dev/null; then
        print_warning "Docker group membership not yet active"
        print_info "Activating docker group for current session using 'sg docker'..."
        echo ""
        
        # Try with sg (substitute group)
        if sg docker -c "docker compose up -d" 2>/dev/null; then
            print_info "Started with sg docker command"
        else
            print_error "Unable to start docker containers"
            print_warning "You need to logout and login again for docker group to take effect"
            echo ""
            echo "Please run these commands:"
            echo "  1. exit"
            echo "  2. SSH back into your system"
            echo "  3. cd ~/n8n && docker compose up -d"
            echo "  4. Re-run this script or continue manually from Step 5"
            exit 1
        fi
    else
        print_info "Running: docker compose up -d"
        docker compose up -d
    fi
    
    echo ""
    print_info "Waiting for n8n to start (5 seconds)..."
    sleep 5
    
    # Check with sg if needed
    if docker ps &>/dev/null; then
        CHECK_CMD="docker ps"
    else
        CHECK_CMD="sg docker -c 'docker ps'"
    fi
    
    if eval $CHECK_CMD | grep -q n8n; then
        print_success "n8n container is running!"
        print_info "n8n is accessible locally at: http://localhost:5678"
        print_info "Container name: n8n"
        echo ""
    else
        print_error "n8n failed to start. Check logs with: docker compose logs"
        exit 1
    fi
}

# Step 5: Install Cloudflared
install_cloudflared() {
    print_header "Step 5: Installing Cloudflare Tunnel (cloudflared)"
    
    print_info "Cloudflare Tunnel creates a secure connection between your server and Cloudflare"
    print_info "Benefits:"
    print_info "  ✓ No port forwarding needed on your router"
    print_info "  ✓ No exposing your home IP address"
    print_info "  ✓ Automatic HTTPS/SSL certificates"
    print_info "  ✓ DDoS protection from Cloudflare"
    echo ""
    
    if command -v cloudflared &> /dev/null; then
        print_warning "cloudflared is already installed"
        cloudflared --version
        echo ""
    else
        print_info "Downloading cloudflared for ARM64 (Raspberry Pi 5)..."
        cd /tmp
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
        
        print_info "Installing cloudflared package..."
        sudo dpkg -i cloudflared-linux-arm64.deb
        rm cloudflared-linux-arm64.deb
        
        print_success "cloudflared installed successfully"
        cloudflared --version
        echo ""
    fi
}

# Step 6: Authenticate Cloudflare
authenticate_cloudflare() {
    print_header "Step 6: Authenticating with Cloudflare"
    
    print_info "You need to authorize this tunnel with your Cloudflare account"
    print_info "A browser will open (or you'll get a URL to visit)"
    echo ""
    
    if [ -d "$HOME/.cloudflared" ] && ls $HOME/.cloudflared/*.json 1> /dev/null 2>&1; then
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
    
    print_warning "ACTION REQUIRED: Please complete the authentication in your browser!"
    print_info "Steps:"
    print_info "  1. Browser will open to Cloudflare login page"
    print_info "  2. Log in with your Cloudflare account"
    print_info "  3. Select the domain: ${DOMAIN}"
    print_info "  4. Click 'Authorize'"
    echo ""
    print_info "Running: cloudflared tunnel login"
    echo ""
    
    cloudflared tunnel login
    
    echo ""
    print_success "Cloudflare authentication completed"
    print_info "Credentials saved to: ~/.cloudflared/"
    echo ""
}

# Step 7: Create Tunnel
create_tunnel() {
    print_header "Step 7: Creating Cloudflare Tunnel"
    
    print_info "A Cloudflare Tunnel creates a persistent connection between your server and Cloudflare"
    print_info "Tunnel name: ${TUNNEL_NAME}"
    echo ""
    
    # Check if tunnel already exists
    if cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
        print_warning "Tunnel '$TUNNEL_NAME' already exists"
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        print_info "Existing tunnel ID: $TUNNEL_ID"
        echo ""
        
        # Check if credentials exist for this tunnel
        print_info "Checking for credentials file..."
        CRED_CHECK=$(find ~ -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1)
        
        if [ -z "$CRED_CHECK" ]; then
            print_warning "Credentials file not found for existing tunnel"
            print_info "This tunnel exists but has no credentials - recreating it..."
            echo ""
            
            print_info "Deleting old tunnel: $TUNNEL_NAME"
            cloudflared tunnel delete "$TUNNEL_NAME"
            sleep 2
            
            print_info "Creating new tunnel: $TUNNEL_NAME"
            cloudflared tunnel create "$TUNNEL_NAME"
            TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
            print_success "Tunnel created with ID: $TUNNEL_ID"
            print_info "Credentials saved to: ~/.cloudflared/${TUNNEL_ID}.json"
            echo ""
        else
            print_success "Using existing tunnel with valid credentials at: $CRED_CHECK"
            echo ""
        fi
    else
        print_info "Creating new tunnel: $TUNNEL_NAME"
        cloudflared tunnel create "$TUNNEL_NAME"
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        print_success "Tunnel created successfully!"
        print_info "Tunnel ID: $TUNNEL_ID"
        print_info "Credentials saved to: ~/.cloudflared/${TUNNEL_ID}.json"
        echo ""
    fi
    
    # Store tunnel ID for later use
    echo "$TUNNEL_ID" > "$N8N_DIR/.tunnel_id"
    print_info "Tunnel ID saved to: $N8N_DIR/.tunnel_id"
    echo ""
}

# Step 8: Configure Tunnel
configure_tunnel() {
    print_header "Step 8: Configuring Cloudflare Tunnel"
    
    TUNNEL_ID=$(cat "$N8N_DIR/.tunnel_id")
    
    print_info "Setting up tunnel configuration for routing traffic"
    print_info "This tells Cloudflare how to forward traffic to your n8n instance"
    echo ""
    
    print_info "Creating /etc/cloudflared/ directory..."
    sudo mkdir -p /etc/cloudflared
    
    print_info "Locating credentials file for tunnel: $TUNNEL_ID"
    # Find the credentials file
    CRED_SOURCE=$(find ~ -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1)
    
    if [ -z "$CRED_SOURCE" ]; then
        print_error "Could not find credentials file for tunnel ${TUNNEL_ID}"
        print_info "Searching for any cloudflared JSON files..."
        find ~ -name "*.json" -path "*cloudflared*" 2>/dev/null
        echo ""
        print_error "Installation cannot continue without credentials file"
        exit 1
    fi
    
    print_success "Found credentials at: $CRED_SOURCE"
    
    print_info "Copying credentials to /etc/cloudflared/${TUNNEL_ID}.json"
    print_info "This allows the cloudflared service (running as root) to access the credentials"
    sudo cp "$CRED_SOURCE" /etc/cloudflared/${TUNNEL_ID}.json
    
    CREDENTIALS_FILE="/etc/cloudflared/${TUNNEL_ID}.json"
    
    print_info "Creating tunnel configuration file: /etc/cloudflared/config.yml"
    print_info "Configuration:"
    print_info "  - Public hostname: ${FULL_DOMAIN}"
    print_info "  - Local service: http://localhost:5678"
    print_info "  - Tunnel ID: ${TUNNEL_ID}"
    echo ""
    
    sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDENTIALS_FILE}

ingress:
  - hostname: ${FULL_DOMAIN}
    service: http://localhost:5678
  - service: http_status:404
EOF
    
    print_success "Tunnel configuration created successfully"
    print_info "Config file: /etc/cloudflared/config.yml"
    echo ""
}

# Step 9: Create DNS Record
create_dns_record() {
    print_header "Step 9: Creating DNS Record"
    
    print_info "Creating a CNAME DNS record in Cloudflare"
    print_info "This points ${FULL_DOMAIN} to your Cloudflare Tunnel"
    print_info "The DNS record is created automatically in your Cloudflare account"
    echo ""
    
    print_info "Running: cloudflared tunnel route dns $TUNNEL_NAME $FULL_DOMAIN"
    
    if cloudflared tunnel route dns "$TUNNEL_NAME" "$FULL_DOMAIN" 2>&1 | grep -q "already exists"; then
        print_warning "DNS record for ${FULL_DOMAIN} already exists"
        print_info "This is fine - using existing record"
    else
        print_success "DNS record created for ${FULL_DOMAIN}"
    fi
    
    echo ""
    print_info "You can verify this in your Cloudflare dashboard:"
    print_info "  Dashboard → ${DOMAIN} → DNS → Records"
    print_info "  Look for: ${SUBDOMAIN} CNAME ${TUNNEL_ID}.cfargotunnel.com"
    echo ""
}

# Step 10: Install and Start Tunnel Service
setup_tunnel_service() {
    print_header "Step 10: Setting up Cloudflare Tunnel Service"
    
    print_info "Installing cloudflared as a system service"
    print_info "This ensures the tunnel starts automatically when your Raspberry Pi boots"
    echo ""
    
    print_info "Running: sudo cloudflared service install"
    sudo cloudflared service install
    
    echo ""
    print_info "Starting cloudflared service..."
    sudo systemctl start cloudflared
    
    print_info "Enabling cloudflared to start on boot..."
    sudo systemctl enable cloudflared
    
    echo ""
    print_info "Waiting for service to initialize (3 seconds)..."
    sleep 3
    
    if sudo systemctl is-active --quiet cloudflared; then
        print_success "Cloudflared service is running!"
        print_info "Service status: active"
        print_info "The tunnel is now connecting your server to Cloudflare's network"
        echo ""
        
        print_info "Service details:"
        sudo systemctl status cloudflared --no-pager | head -n 10
        echo ""
    else
        print_error "Cloudflared service failed to start"
        print_warning "Checking service logs..."
        echo ""
        sudo journalctl -u cloudflared -n 20 --no-pager
        echo ""
        print_info "You can check logs with: sudo journalctl -u cloudflared -f"
        exit 1
    fi
}

# Step 11: Create Backup Script
create_backup_script() {
    print_header "Step 11: Creating Backup Script"
    
    cat > "$HOME/backup-n8n.sh" <<'EOF'
#!/bin/bash
BACKUP_DIR=~/n8n-backups
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR
tar -czf $BACKUP_DIR/n8n-backup-$DATE.tar.gz ~/n8n/data

# Keep only last 7 backups
ls -t $BACKUP_DIR/n8n-backup-*.tar.gz | tail -n +8 | xargs rm -f 2>/dev/null

echo "Backup completed: n8n-backup-$DATE.tar.gz"
EOF
    
    chmod +x "$HOME/backup-n8n.sh"
    print_success "Backup script created at ~/backup-n8n.sh"
    print_info "Run it anytime with: ~/backup-n8n.sh"
    print_info "Backups will be stored in: ~/n8n-backups/"
    echo ""
}



# Final Summary
print_summary() {
    print_header "Installation Complete! 🎉"
    
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   n8n Installation Successful!                     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BLUE}📍 Access Information:${NC}"
    echo -e "   ${GREEN}URL: https://${FULL_DOMAIN}${NC}"
    echo -e "   ${YELLOW}Please wait 1-2 minutes for DNS propagation${NC}"
    echo ""
    
    echo -e "${BLUE}📁 Installation Directories:${NC}"
    echo -e "   n8n Data:      ${N8N_DIR}/data"
    echo -e "   Config:        ${N8N_DIR}/docker-compose.yml"
    echo -e "   Backups:       ~/n8n-backups/"
    echo -e "   Tunnel Config: /etc/cloudflared/config.yml"
    echo ""
    
    echo -e "${BLUE}🔧 Service Information:${NC}"
    echo -e "   Container:     n8n (Docker)"
    echo -e "   Tunnel:        ${TUNNEL_NAME}"
    echo -e "   Tunnel ID:     $(cat $N8N_DIR/.tunnel_id)"
    echo ""
    
    echo -e "${BLUE}📝 First Steps:${NC}"
    echo -e "   1. Wait 1-2 minutes for DNS to propagate"
    echo -e "   2. Visit: ${GREEN}https://${FULL_DOMAIN}${NC}"
    echo -e "   3. Create your owner account (first user)"
    echo -e "   4. Set up your email and password"
    echo -e "   5. Start creating workflows!"
    echo ""
    
    echo -e "${BLUE}💡 Useful Commands:${NC}"
    echo ""
    echo -e "${YELLOW}Docker Management:${NC}"
    echo -e "   cd ~/n8n && docker compose ps          # Check status"
    echo -e "   cd ~/n8n && docker compose logs -f     # View logs"
    echo -e "   cd ~/n8n && docker compose restart     # Restart n8n"
    echo -e "   cd ~/n8n && docker compose down        # Stop n8n"
    echo -e "   cd ~/n8n && docker compose up -d       # Start n8n"
    echo -e "   cd ~/n8n && docker compose pull        # Update n8n"
    echo ""
    
    echo -e "${YELLOW}Cloudflare Tunnel:${NC}"
    echo -e "   sudo systemctl status cloudflared      # Check tunnel status"
    echo -e "   sudo systemctl restart cloudflared     # Restart tunnel"
    echo -e "   sudo journalctl -u cloudflared -f      # View tunnel logs"
    echo -e "   cloudflared tunnel list                # List all tunnels"
    echo ""
    
    echo -e "${YELLOW}Backup & Maintenance:${NC}"
    echo -e "   ~/backup-n8n.sh                        # Create backup"
    echo -e "   ls -lh ~/n8n-backups/                  # View backups"
    echo ""
    
    echo -e "${BLUE}🔒 Security Notes:${NC}"
    echo -e "   ✓ Traffic is encrypted via Cloudflare Tunnel"
    echo -e "   ✓ No ports exposed on your router"
    echo -e "   ✓ Your home IP address remains private"
    echo -e "   ✓ Automatic HTTPS/SSL certificates"
    echo -e "   ✓ DDoS protection from Cloudflare"
    echo ""
    
    echo -e "${BLUE}📊 System Status:${NC}"
    echo -e "   n8n Status:    $(sudo docker ps --filter name=n8n --format '{{.Status}}')"
    echo -e "   Tunnel Status: $(sudo systemctl is-active cloudflared)"
    echo ""
    
    echo -e "${BLUE}🆘 Troubleshooting:${NC}"
    echo -e "   If n8n is not accessible:"
    echo -e "     • Wait 2-3 minutes for DNS propagation"
    echo -e "     • Check n8n: docker compose logs n8n"
    echo -e "     • Check tunnel: sudo journalctl -u cloudflared -f"
    echo -e "     • Verify DNS in Cloudflare dashboard"
    echo ""
    
    echo -e "${BLUE}📚 Resources:${NC}"
    echo -e "   n8n Docs:       https://docs.n8n.io"
    echo -e "   Cloudflare:     https://dash.cloudflare.com"
    echo -e "   Community:      https://community.n8n.io"
    echo ""
    
    print_warning "IMPORTANT: Create your owner account now at https://${FULL_DOMAIN}"
    print_info "The first user to register will become the instance owner"
    echo ""
    
    echo -e "${GREEN}Thank you for installing n8n! Happy automating! 🚀${NC}"
    echo ""
}

# Main Installation Flow
main() {
    clear
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║              n8n Automated Installation Script v2.0                   ║"
    echo "║                                                                       ║"
    echo "║           Installing n8n with Docker + Cloudflare Tunnel              ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
    
    echo -e "${BLUE}📋 Installation Details:${NC}"
    echo -e "   Domain:              ${GREEN}https://${FULL_DOMAIN}${NC}"
    echo -e "   Installation Dir:    ${GREEN}${N8N_DIR}${NC}"
    echo -e "   Tunnel Name:         ${GREEN}${TUNNEL_NAME}${NC}"
    echo -e "   Timezone:            ${GREEN}${TIMEZONE}${NC}"
    echo ""
    
    echo -e "${BLUE}📦 What will be installed:${NC}"
    echo -e "   ✓ Docker & Docker Compose"
    echo -e "   ✓ n8n workflow automation"
    echo -e "   ✓ Cloudflare Tunnel (cloudflared)"
    echo -e "   ✓ Automatic startup services"
    echo -e "   ✓ Backup script"
    echo ""
    
    echo -e "${YELLOW}⚠️  Requirements:${NC}"
    echo -e "   • Active Cloudflare account"
    echo -e "   • Domain ${DOMAIN} added to Cloudflare"
    echo -e "   • Internet connection"
    echo -e "   • ~15-20 minutes of installation time"
    echo ""
    
    echo -e "${BLUE}ℹ️  Installation Steps (11 total):${NC}"
    echo -e "   1. Update system & install dependencies"
    echo -e "   2. Install Docker"
    echo -e "   3. Setup n8n with Docker Compose"
    echo -e "   4. Start n8n container"
    echo -e "   5. Install Cloudflare Tunnel"
    echo -e "   6. Authenticate with Cloudflare (requires browser)"
    echo -e "   7. Create Cloudflare Tunnel"
    echo -e "   8. Configure tunnel routing"
    echo -e "   9. Create DNS record"
    echo -e "   10. Setup tunnel as system service"
    echo -e "   11. Create backup script"
    echo ""
    
    read -p "Press Enter to start installation or Ctrl+C to cancel..."
    echo ""
    
    check_root
    install_dependencies
    install_docker
    setup_n8n_docker
    start_n8n
    install_cloudflared
    authenticate_cloudflare
    create_tunnel
    configure_tunnel
    create_dns_record
    setup_tunnel_service
    create_backup_script
    print_summary
}

# Run main function
main
