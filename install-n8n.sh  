#!/bin/bash

# n8n Automated Installation Script for Raspberry Pi 5
# With Docker and Cloudflare Tunnel

set -e  # Exit on any error

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load configuration
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found!"
    echo "Please create .env file with your configuration"
    exit 1
fi

source "$SCRIPT_DIR/.env"

# Calculate full domain
FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

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

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

check_root() {
    if [ "$EUID" -eq 0 ]; then 
        print_error "Please do not run this script as root or with sudo"
        exit 1
    fi
}

# Step 1: Update System
install_dependencies() {
    print_header "Step 1: Updating System and Installing Dependencies"
    
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y curl wget git nano
    
    print_success "System updated and dependencies installed"
}

# Step 2: Install Docker
install_docker() {
    print_header "Step 2: Installing Docker"
    
    if command -v docker &> /dev/null; then
        print_warning "Docker is already installed"
        docker --version
    else
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
        
        print_info "Adding user to docker group..."
        sudo usermod -aG docker $USER
        
        print_success "Docker installed successfully"
    fi
}

# Step 3: Create n8n Directory and Docker Compose
setup_n8n_docker() {
    print_header "Step 3: Setting up n8n with Docker Compose"
    
    print_info "Creating n8n directory structure..."
    mkdir -p "$N8N_DIR/data"
    cd "$N8N_DIR"
    
    print_info "Copying docker-compose.yml..."
    if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
        cp "$SCRIPT_DIR/docker-compose.yml" "$N8N_DIR/"
        
        # Create .env for docker-compose
        cat > "$N8N_DIR/.env" <<EOF
N8N_HOST=${FULL_DOMAIN}
TIMEZONE=${TIMEZONE}
EOF
        print_success "Docker Compose configuration created"
    else
        print_error "docker-compose.yml not found in script directory!"
        exit 1
    fi
}

# Step 4: Start n8n
start_n8n() {
    print_header "Step 4: Starting n8n"
    
    cd "$N8N_DIR"
    
    # Check if user has docker permissions
    if ! docker ps &>/dev/null; then
        print_warning "Docker group membership not yet active"
        print_info "Activating docker group for current session..."
        
        if sg docker -c "docker compose up -d" 2>/dev/null; then
            print_info "Started with sg docker"
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
        docker compose up -d
    fi
    
    sleep 5
    
    # Check with sg if needed
    if docker ps &>/dev/null; then
        CHECK_CMD="docker ps"
    else
        CHECK_CMD="sg docker -c 'docker ps'"
    fi
    
    if eval $CHECK_CMD | grep -q n8n; then
        print_success "n8n is running!"
    else
        print_error "n8n failed to start. Check logs with: docker compose logs"
        exit 1
    fi
}

# Step 5: Install Cloudflared
install_cloudflared() {
    print_header "Step 5: Installing Cloudflare Tunnel (cloudflared)"
    
    if command -v cloudflared &> /dev/null; then
        print_warning "cloudflared is already installed"
        cloudflared --version
    else
        print_info "Downloading cloudflared for ARM64..."
        cd /tmp
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
        
        print_info "Installing cloudflared..."
        sudo dpkg -i cloudflared-linux-arm64.deb
        rm cloudflared-linux-arm64.deb
        
        print_success "cloudflared installed successfully"
    fi
}

# Step 6: Authenticate Cloudflare
authenticate_cloudflare() {
    print_header "Step 6: Authenticating with Cloudflare"
    
    if [ -d "$HOME/.cloudflared" ] && ls $HOME/.cloudflared/*.json 1> /dev/null 2>&1; then
        print_warning "Cloudflare credentials already exist"
        read -p "Do you want to re-authenticate? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping authentication"
            return
        fi
    fi
    
    print_info "Opening browser for Cloudflare authentication..."
    print_warning "Please authorize the tunnel in your browser"
    cloudflared tunnel login
    
    print_success "Cloudflare authentication completed"
}

# Step 7: Create Tunnel
create_tunnel() {
    print_header "Step 7: Creating Cloudflare Tunnel"
    
    # Check if tunnel already exists
    if cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
        print_warning "Tunnel '$TUNNEL_NAME' already exists"
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        print_info "Existing tunnel ID: $TUNNEL_ID"
        
        # Check if credentials exist for this tunnel
        CRED_CHECK=$(find ~ -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1)
        
        if [ -z "$CRED_CHECK" ]; then
            print_warning "Credentials file not found for existing tunnel"
            print_info "Deleting and recreating tunnel..."
            
            cloudflared tunnel delete "$TUNNEL_NAME"
            sleep 2
            
            print_info "Creating new tunnel: $TUNNEL_NAME"
            cloudflared tunnel create "$TUNNEL_NAME"
            TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
            print_success "Tunnel created with ID: $TUNNEL_ID"
        else
            print_success "Using existing tunnel with valid credentials"
        fi
    else
        print_info "Creating new tunnel: $TUNNEL_NAME"
        cloudflared tunnel create "$TUNNEL_NAME"
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
        print_success "Tunnel created with ID: $TUNNEL_ID"
    fi
    
    # Store tunnel ID for later use
    echo "$TUNNEL_ID" > "$N8N_DIR/.tunnel_id"
}

# Step 8: Configure Tunnel
configure_tunnel() {
    print_header "Step 8: Configuring Cloudflare Tunnel"
    
    TUNNEL_ID=$(cat "$N8N_DIR/.tunnel_id")
    
    print_info "Creating tunnel configuration..."
    sudo mkdir -p /etc/cloudflared
    
    print_info "Locating credentials file..."
    # Find the credentials file
    CRED_SOURCE=$(find ~ -name "${TUNNEL_ID}.json" -path "*cloudflared*" 2>/dev/null | head -n 1)
    
    if [ -z "$CRED_SOURCE" ]; then
        print_error "Could not find credentials file for tunnel ${TUNNEL_ID}"
        print_info "Searching for any cloudflared JSON files..."
        find ~ -name "*.json" -path "*cloudflared*" 2>/dev/null
        exit 1
    fi
    
    print_info "Found credentials at: $CRED_SOURCE"
    print_info "Copying credentials to /etc/cloudflared/..."
    sudo cp "$CRED_SOURCE" /etc/cloudflared/${TUNNEL_ID}.json
    
    CREDENTIALS_FILE="/etc/cloudflared/${TUNNEL_ID}.json"
    
    sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDENTIALS_FILE}

ingress:
  - hostname: ${FULL_DOMAIN}
    service: http://localhost:5678
  - service: http_status:404
EOF
    
    print_success "Tunnel configuration created"
}

# Step 9: Create DNS Record
create_dns_record() {
    print_header "Step 9: Creating DNS Record"
    
    print_info "Creating DNS record for ${FULL_DOMAIN}..."
    
    if cloudflared tunnel route dns "$TUNNEL_NAME" "$FULL_DOMAIN" 2>&1 | grep -q "already exists"; then
        print_warning "DNS record already exists"
    else
        cloudflared tunnel route dns "$TUNNEL_NAME" "$FULL_DOMAIN"
        print_success "DNS record created for ${FULL_DOMAIN}"
    fi
}

# Step 10: Install and Start Tunnel Service
setup_tunnel_service() {
    print_header "Step 10: Setting up Cloudflare Tunnel Service"
    
    print_info "Installing cloudflared as a system service..."
    sudo cloudflared service install
    
    print_info "Starting cloudflared service..."
    sudo systemctl start cloudflared
    sudo systemctl enable cloudflared
    
    sleep 3
    
    if sudo systemctl is-active --quiet cloudflared; then
        print_success "Cloudflared service is running"
    else
        print_error "Cloudflared service failed to start"
        print_info "Check logs with: sudo journalctl -u cloudflared -f"
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
}

# Final Summary
print_summary() {
    print_header "Installation Complete! 🎉"
    
    echo -e "${GREEN}n8n is now accessible at: https://${FULL_DOMAIN}${NC}\n"
    
    echo -e "${BLUE}Important Information:${NC}"
    echo -e "  • n8n Directory: ${N8N_DIR}"
    echo -e "  • Data Directory: ${N8N_DIR}/data"
    echo -e "  • Tunnel Name: ${TUNNEL_NAME}"
    echo -e "  • Backup Script: ~/backup-n8n.sh\n"
    
    echo -e "${BLUE}Next Steps:${NC}"
    echo -e "  1. Wait 1-2 minutes for DNS propagation"
    echo -e "  2. Visit ${GREEN}https://${FULL_DOMAIN}${NC}"
    echo -e "  3. Create your owner account through the web interface"
    echo -e "  4. Run ${YELLOW}./import-workflows.sh${NC} to import workflows from Google Drive\n"
    
    echo -e "${BLUE}Useful Commands:${NC}"
    echo -e "  ${YELLOW}Docker:${NC}"
    echo -e "    cd ~/n8n && docker compose logs -f    # View n8n logs"
    echo -e "    cd ~/n8n && docker compose restart     # Restart n8n"
    echo -e "    cd ~/n8n && docker compose down        # Stop n8n"
    echo -e "    cd ~/n8n && docker compose up -d       # Start n8n\n"
    
    echo -e "  ${YELLOW}Cloudflare Tunnel:${NC}"
    echo -e "    sudo systemctl status cloudflared      # Check tunnel status"
    echo -e "    sudo systemctl restart cloudflared     # Restart tunnel"
    echo -e "    sudo journalctl -u cloudflared -f      # View tunnel logs\n"
    
    echo -e "  ${YELLOW}Backup:${NC}"
    echo -e "    ~/backup-n8n.sh                        # Create backup\n"
}

# Main Installation Flow
main() {
    clear
    print_header "n8n Automated Installation"
    echo -e "Domain: ${GREEN}${FULL_DOMAIN}${NC}"
    echo -e "Installation Directory: ${GREEN}${N8N_DIR}${NC}\n"
    
    read -p "Press Enter to start installation or Ctrl+C to cancel..."
    
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