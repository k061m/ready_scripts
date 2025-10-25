#!/bin/bash

# n8n Automated Installation Script for Raspberry Pi 5
# With Docker, Cloudflare Tunnel, and Rclone Backup Restore

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

print_success() { echo -e "${GREEN}[OK] $1${NC}"; }
print_error()   { echo -e "${RED}[ERROR] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[WARN] $1${NC}"; }
print_info()    { echo -e "${BLUE}[INFO] $1${NC}"; }

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
    print_info "Dependencies: curl, wget, git, nano, unzip"
    echo ""
    
    print_info "Running: sudo apt update..."
    sudo apt update
    
    print_info "Running: sudo apt upgrade - this may take a few minutes..."
    sudo apt upgrade -y
    
    print_info "Installing essential tools..."
    sudo apt install -y curl wget git nano unzip
    
    print_success "System updated and dependencies installed"
    echo ""
}

# Step 2: Install Docker
install_docker() {
    print_header "Step 2: Installing Docker"
    
    print_info "Docker is a platform for running containerized applications"
    print_info "We'll use Docker to run n8n in an isolated, reproducible environment"
    echo ""
    
    if command -v docker > /dev/null 2>&1; then
        print_warning "Docker is already installed"
        docker --version
        echo ""
    else
        print_info "Downloading Docker installation script from get.docker.com..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        
        print_info "Installing Docker - this may take a few minutes..."
        sudo sh get-docker.sh
        rm get-docker.sh
        
        print_info "Adding current user to docker group: $USER"
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
    print_success "Created: $N8N_DIR/data - this will store your workflows and credentials"
    echo ""
    
    print_info "Creating docker-compose.yml configuration file..."
    print_info "Configuration details:"
    print_info "  - Domain: https://${FULL_DOMAIN}"
    print_info "  - Port: 5678 local"
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
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_SAVE_ON_ERROR=all
      - EXECUTIONS_DATA_SAVE_ON_SUCCESS=all
      - EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=true
      - EXECUTIONS_DATA_PRUNE_TIMEOUT=3600
      - N8N_ENCRYPTION_KEY=QPwMKA7gz3tIsSWcEiZRmpG9IkDOjsUIETOXA+lWPBQ=
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
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
    if ! docker ps > /dev/null 2>&1; then
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
    print_info "Waiting for n8n to start - 5 seconds..."
    sleep 5
    
    # Check with sg if needed
    if docker ps > /dev/null 2>&1; then
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
    print_info "  • No port forwarding needed on your router"
    print_info "  • No exposing your home IP address"
    print_info "  • Automatic HTTPS/SSL certificates"
    print_info "  • DDoS protection from Cloudflare"
    echo ""
    
    if command -v cloudflared > /dev/null 2>&1; then
        print_warning "cloudflared is already installed"
        cloudflared --version
        echo ""
    else
        print_info "Downloading cloudflared for ARM64 - Raspberry Pi 5..."
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
    print_info "A browser will open or you'll get a URL to visit"
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
    print_info "This allows the cloudflared service running as root to access the credentials"
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
    
    # Check if service already exists
    if [ -f "/etc/systemd/system/cloudflared.service" ]; then
        print_warning "Cloudflared service already exists"
        print_info "Stopping existing service..."
        sudo systemctl stop cloudflared 2>/dev/null || true
        
        print_info "Uninstalling old service..."
        sudo cloudflared service uninstall 2>/dev/null || true
        
        print_info "Waiting 2 seconds..."
        sleep 2
    fi
    
    print_info "Running: sudo cloudflared service install"
    sudo cloudflared service install
    
    echo ""
    print_info "Starting cloudflared service..."
    sudo systemctl start cloudflared
    
    print_info "Enabling cloudflared to start on boot..."
    sudo systemctl enable cloudflared
    
    echo ""
    print_info "Waiting for service to initialize - 3 seconds..."
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
BACKUP_NAME="n8n_backup_$DATE"

mkdir -p $BACKUP_DIR
mkdir -p $BACKUP_DIR/$BACKUP_NAME
cp -r ~/n8n/data/* $BACKUP_DIR/$BACKUP_NAME/ 2>/dev/null || true
tar -czf $BACKUP_DIR/${BACKUP_NAME}.tar.gz -C $BACKUP_DIR $BACKUP_NAME
rm -rf $BACKUP_DIR/$BACKUP_NAME

# Keep only last 7 backups
ls -t $BACKUP_DIR/n8n_backup_*.tar.gz | tail -n +8 | xargs rm -f 2>/dev/null

echo "Backup completed: ${BACKUP_NAME}.tar.gz"
EOF
    
    chmod +x "$HOME/backup-n8n.sh"
    print_success "Backup script created at ~/backup-n8n.sh"
    print_info "Run it anytime with: ~/backup-n8n.sh"
    print_info "Backups will be stored in: ~/n8n-backups/"
    echo ""
}

# Step 12: Install Rclone and Restore Backup
install_rclone_and_restore() {
    if [[ ! $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        print_info "Skipping backup restore (user chose not to restore)"
        echo ""
        return
    fi
        
    print_header "Step 12: Installing Rclone and Restoring Backup"
    
    print_info "Rclone allows you to sync files with cloud storage providers"
    print_info "We'll install it in the n8n container and restore your backup from Google Drive"
    echo ""
    
    # Download and install rclone
    print_info "Downloading rclone for ARM64..."
    cd /tmp
    
    if [ -f "rclone-current-linux-arm64.zip" ]; then
        print_warning "Rclone zip already exists in /tmp, removing..."
        rm -f rclone-current-linux-arm64.zip
    fi
    
    wget -q --show-progress https://downloads.rclone.org/rclone-current-linux-arm64.zip
    
    print_info "Extracting rclone..."
    unzip -q rclone-current-linux-arm64.zip
    
    print_info "Navigating to rclone directory..."
    cd rclone-*-linux-arm64
    
    print_success "Rclone downloaded and extracted"
    echo ""
    
    # Copy rclone to n8n container
    print_info "Copying rclone binary to n8n container..."
    sudo docker cp rclone n8n:/usr/local/bin/rclone
    
    print_info "Setting execute permissions on rclone..."
    sudo docker exec -u root n8n chmod +x /usr/local/bin/rclone
    
    print_info "Verifying rclone installation..."
    if sudo docker exec n8n rclone version > /dev/null 2>&1; then
        print_success "Rclone installed successfully in n8n container"
        sudo docker exec n8n rclone version | head -n 1
        echo ""
    else
        print_error "Failed to install rclone in container"
        return 1
    fi
    
    # Display encryption key
    print_info "Current n8n encryption key:"
    ENCRYPTION_KEY=$(sudo docker exec n8n printenv | grep N8N_ENCRYPTION_KEY | cut -d'=' -f2)
    echo -e "${YELLOW}${ENCRYPTION_KEY}${NC}"
    print_warning "Make sure your backup was created with this same encryption key!"
    echo ""
    
    # Configure rclone
    print_header "Configuring Rclone for Google Drive"
    print_warning "ACTION REQUIRED: Configure rclone to access your Google Drive"
    print_info "Steps:"
    print_info "  1. Choose 'n' for new remote"
    print_info "  2. Enter a name (e.g., 'gdrive')"
    print_info "  3. Select '15' for Google Drive"
    print_info "  4. Leave client_id and client_secret blank (press Enter twice)"
    print_info "  5. Choose '1' for full access"
    print_info "  6. Leave root_folder_id blank (press Enter)"
    print_info "  7. Leave service_account_file blank (press Enter)"
    print_info "  8. Choose 'n' for advanced config"
    print_info "  9. Choose 'y' to use auto config"
    print_info "  10. Complete OAuth in browser"
    print_info "  11. Choose 'n' for team drive"
    print_info "  12. Choose 'y' to confirm"
    print_info "  13. Choose 'q' to quit config"
    echo ""
    read -p "Press Enter when ready to configure rclone..."
    echo ""
    
    sudo docker exec -it -u node n8n rclone config
    
    echo ""
    print_success "Rclone configuration completed"
    echo ""
    
    # List remotes to get the configured name
    print_info "Configured remotes:"
    sudo docker exec n8n rclone listremotes
    echo ""
    
    read -p "Enter the name of your rclone remote (e.g., gdrive): " REMOTE_NAME
    while [[ -z "$REMOTE_NAME" ]]; do
        print_error "Remote name cannot be empty"
        read -p "Enter the name of your rclone remote: " REMOTE_NAME
    done
    
    # Remove trailing colon if present
    REMOTE_NAME=${REMOTE_NAME%:}
    
    print_info "Using remote: ${REMOTE_NAME}"
    echo ""
    
    # Find latest backup
    print_header "Finding Latest Backup in Google Drive"
    print_info "Searching for n8n backups in ${REMOTE_NAME}:..."
    echo ""
    
    print_info "Listing backup files:"
    sudo docker exec n8n rclone lsf "${REMOTE_NAME}:" --recursive --include "n8n_backup_*.tar.gz" | grep '\.tar\.gz$' | sort -r | head -n 10
    echo ""
    
    LATEST_BACKUP=$(sudo docker exec n8n rclone lsf "${REMOTE_NAME}:" --recursive --include "n8n_backup_*.tar.gz" | grep '\.tar\.gz$' | sort -r | head -n 1 | tr -d '\n\r' | xargs)
    
    if [ -z "$LATEST_BACKUP" ]; then
        print_error "No backups found matching pattern 'n8n_backup_*.tar.gz'"
        print_info "Please check your Google Drive and ensure backups are in the remote"
        echo ""
        read -p "Enter backup filename manually (with full path if in subfolder): " LATEST_BACKUP
    else
        print_success "Found latest backup: ${LATEST_BACKUP}"
        echo ""
        read -p "Use this backup? (Y/n): " -n 1 -r USE_LATEST
        echo ""
        if [[ $USE_LATEST =~ ^[Nn]$ ]]; then
            read -p "Enter backup filename: " LATEST_BACKUP
        fi
    fi
    
    BACKUP_FILENAME=$(basename "$LATEST_BACKUP" .tar.gz)
    BACKUP_NAME="$BACKUP_FILENAME"
    
    # Download backup
    print_header "Downloading Backup from Google Drive"
    print_info "Downloading: ${LATEST_BACKUP}"
    print_info "Destination: /home/$USER/${BACKUP_FILENAME}.tar.gz"
    echo ""
    
    cd "/home/$USER"
    print_info "Downloading file from rclone..."
    print_info "Command: rclone copyto ${REMOTE_NAME}:${LATEST_BACKUP} /home/node/backup_temp.tar.gz"
    sudo docker exec -u node n8n rclone copyto "${REMOTE_NAME}:${LATEST_BACKUP}" /home/node/backup_temp.tar.gz
    
    # Verify file exists in container
    print_info "Verifying file exists in container..."
    CONTAINER_FILE_SIZE=$(sudo docker exec n8n ls -lh /home/node/backup_temp.tar.gz 2>/dev/null | awk '{print $5}' || echo "not found")
    print_info "File size in container: $CONTAINER_FILE_SIZE"
    
    # Copy backup out of container to host
    print_info "Copying backup from container to host..."
    print_info "Source: n8n:/home/node/backup_temp.tar.gz"
    print_info "Dest: /home/$USER/${BACKUP_FILENAME}.tar.gz"
    sudo docker cp "n8n:/home/node/backup_temp.tar.gz" "/home/$USER/${BACKUP_FILENAME}.tar.gz"
    
    # Verify what was copied to host
    print_info "Verifying file on host..."
    if [ -d "/home/$USER/${BACKUP_FILENAME}.tar.gz" ]; then
        print_warning "ERROR: Destination is a directory! Contents:"
        ls -lah "/home/$USER/${BACKUP_FILENAME}.tar.gz/"
    elif [ -f "/home/$USER/${BACKUP_FILENAME}.tar.gz" ]; then
        print_success "File copied successfully"
    else
        print_warning "File does not exist at destination"
    fi
    
    if [ -f "/home/$USER/${BACKUP_FILENAME}.tar.gz" ]; then
        print_success "Backup downloaded successfully to /home/$USER/${BACKUP_FILENAME}.tar.gz"
        BACKUP_SIZE=$(du -h "/home/$USER/${BACKUP_FILENAME}.tar.gz" 2>/dev/null | cut -f1)
        print_info "Backup size: ${BACKUP_SIZE}"
        echo ""
    elif [ -d "/home/$USER/${BACKUP_FILENAME}.tar.gz" ]; then
        print_error "ERROR: Destination path is a directory instead of a file!"
        print_info "Trying to recover by removing directory and retrying..."
        rm -rf "/home/$USER/${BACKUP_FILENAME}.tar.gz"
        sudo docker cp "n8n:/home/node/backup_temp.tar.gz" "/home/$USER/${BACKUP_FILENAME}.tar.gz"
        
        if [ ! -f "/home/$USER/${BACKUP_FILENAME}.tar.gz" ]; then
            print_error "Failed to copy backup file from container"
            echo ""
            return 1
        fi
    else
        print_error "Failed to copy backup file from container"
        echo ""
        return 1
    fi
    
    # Verify it's a valid tar.gz file
    print_info "Verifying backup file integrity..."
    
    # Check what we actually have
    LOCAL_FILE_TYPE=$(file "/home/$USER/${BACKUP_FILENAME}.tar.gz" 2>/dev/null || echo "unknown")
    print_info "File type detected: $LOCAL_FILE_TYPE"
    
    # If it's a directory, something went wrong with the copy
    if [ -d "/home/$USER/${BACKUP_FILENAME}.tar.gz" ]; then
        print_error "ERROR: File is a directory, not a gzip file!"
        print_info "This means docker cp copied the directory structure instead of the file"
        print_warning "Attempting to find the actual tar.gz file inside..."
        
        # Look for tar.gz files inside
        if [ -f "/home/$USER/${BACKUP_FILENAME}.tar.gz/${BACKUP_FILENAME}.tar.gz" ]; then
            print_info "Found nested tar.gz file, using it..."
            mv "/home/$USER/${BACKUP_FILENAME}.tar.gz/${BACKUP_FILENAME}.tar.gz" "/home/$USER/${BACKUP_FILENAME}_fixed.tar.gz"
            rm -rf "/home/$USER/${BACKUP_FILENAME}.tar.gz"
            BACKUP_FILENAME="${BACKUP_FILENAME}_fixed"
        else
            print_error "Could not find backup file. Directory contents:"
            find "/home/$USER/${BACKUP_FILENAME}.tar.gz" -type f 2>/dev/null | head -20
            return 1
        fi
    fi
    
    if ! file "/home/$USER/${BACKUP_FILENAME}.tar.gz" 2>/dev/null | grep -q "gzip compressed data"; then
        print_warning "File does not appear to be gzip compressed"
        print_info "Attempting extraction anyway..."
    else
        print_success "Backup file verified as gzip"
    fi
    echo ""
    
    # Extract backup
    print_header "Extracting Backup"
    print_info "Extracting: ${BACKUP_FILENAME}.tar.gz"
    print_info "Directory listing before extraction:"
    ls -lah "/home/$USER/${BACKUP_FILENAME}.tar.gz" 2>/dev/null || echo "File not found"
    echo ""
    
    cd "/home/$USER"
    if tar -tzf "${BACKUP_FILENAME}.tar.gz" > /dev/null 2>&1; then
        print_info "Backup file is valid tar.gz, extracting..."
        tar -xzf "${BACKUP_FILENAME}.tar.gz"
    else
        print_error "File is not a valid tar.gz archive"
        return 1
    fi
    
    if [ -d "/home/$USER/${BACKUP_NAME}" ]; then
        print_success "Backup extracted to: /home/$USER/${BACKUP_NAME}"
        print_info "Contents:"
        ls -lh "/home/$USER/${BACKUP_NAME}"
        echo ""
    else
        print_error "Failed to extract backup"
        return 1
    fi
    
    # Check for workflow and credential files
    WORKFLOWS_FILE=""
    CREDENTIALS_FILE=""
    
    if [ -f "/home/$USER/${BACKUP_NAME}/workflows.json" ]; then
        WORKFLOWS_FILE="/home/$USER/${BACKUP_NAME}/workflows.json"
        print_success "Found workflows.json"
    else
        print_warning "workflows.json not found in backup"
    fi
    
    if [ -f "/home/$USER/${BACKUP_NAME}/credentials.json" ]; then
        CREDENTIALS_FILE="/home/$USER/${BACKUP_NAME}/credentials.json"
        print_success "Found credentials.json"
    else
        print_warning "credentials.json not found in backup"
    fi
    
    echo ""
    
    if [ -z "$WORKFLOWS_FILE" ] && [ -z "$CREDENTIALS_FILE" ]; then
        print_error "No workflows.json or credentials.json found in backup"
        print_info "Backup structure:"
        find "/home/$USER/${BACKUP_NAME}" -type f
        echo ""
        return 1
    fi
    
    # Import workflows
    if [ -n "$WORKFLOWS_FILE" ]; then
        print_header "Importing Workflows"
        print_info "Copying workflows.json to container..."
        sudo docker cp "$WORKFLOWS_FILE" n8n:/tmp/workflows.json
        
        print_info "Importing workflows into n8n..."
        if sudo docker exec n8n n8n import:workflow --input=/tmp/workflows.json; then
            print_success "Workflows imported successfully!"
            echo ""
        else
            print_error "Failed to import workflows"
            print_warning "This might be normal if no workflows exist or format is different"
            echo ""
        fi
    fi
    
    # Import credentials
    if [ -n "$CREDENTIALS_FILE" ]; then
        print_header "Importing Credentials"
        print_info "Copying credentials.json to container..."
        sudo docker cp "$CREDENTIALS_FILE" n8n:/tmp/credentials.json
        
        print_info "Importing credentials into n8n..."
        if sudo docker exec n8n n8n import:credentials --input=/tmp/credentials.json; then
            print_success "Credentials imported successfully!"
            echo ""
        else
            print_error "Failed to import credentials"
            print_warning "This might be normal if no credentials exist or format is different"
            echo ""
        fi
    fi
    
    # Cleanup
    print_header "Cleanup"
    print_info "Cleaning up temporary files..."
    
    print_info "Removing extracted backup directory..."
    rm -rf "/home/$USER/${BACKUP_NAME}"
    
    print_info "Removing backup archive..."
    rm -f "/home/$USER/${BACKUP_NAME}.tar.gz"
    
    print_info "Cleaning up rclone installation files..."
    rm -rf /tmp/rclone-*
    
    print_success "Cleanup completed"
    echo ""
    
    # Restart n8n to ensure changes take effect
    print_header "Restarting n8n"
    print_info "Restarting n8n container to apply imported data..."
    cd "$N8N_DIR"
    docker compose restart
    
    print_info "Waiting for n8n to restart - 10 seconds..."
    sleep 10
    
    if docker ps | grep -q n8n; then
        print_success "n8n restarted successfully with imported data!"
        echo ""
    else
        print_warning "n8n container may not be running. Check with: docker compose logs"
        echo ""
    fi
    
    print_success "Backup restore completed!"
    print_info "Your workflows and credentials have been imported"
    print_warning "Note: You may need to reconfigure some credentials if they use OAuth or external authentication"
    echo ""
}

# Final Summary
print_summary() {
    print_header "Installation Complete!"
    
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   n8n Installation Successful!                     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BLUE}Access Information:${NC}"
    echo -e "   ${GREEN}URL: https://${FULL_DOMAIN}${NC}"
    echo -e "   ${YELLOW}Please wait 1-2 minutes for DNS propagation${NC}"
    echo ""
    
    echo -e "${BLUE}Installation Directories:${NC}"
    echo -e "   n8n Data:      ${N8N_DIR}/data"
    echo -e "   Config:        ${N8N_DIR}/docker-compose.yml"
    echo -e "   Backups:       ~/n8n-backups/"
    echo -e "   Tunnel Config: /etc/cloudflared/config.yml"
    echo ""
    
    echo -e "${BLUE}Service Information:${NC}"
    echo -e "   Container:     n8n (Docker)"
    echo -e "   Tunnel:        ${TUNNEL_NAME}"
    echo -e "   Tunnel ID:     $(cat $N8N_DIR/.tunnel_id)"
    if [[ $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        echo -e "   Backup:        ${GREEN}Restored${NC}"
    fi
    echo ""
    
    echo -e "${BLUE}First Steps:${NC}"
    if [[ $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        echo -e "   1. Wait 1-2 minutes for DNS to propagate"
        echo -e "   2. Visit: ${GREEN}https://${FULL_DOMAIN}${NC}"
        echo -e "   3. Login with your restored credentials"
        echo -e "   4. Check your workflows and credentials"
        echo -e "   5. Reconfigure OAuth credentials if needed"
    else
        echo -e "   1. Wait 1-2 minutes for DNS to propagate"
        echo -e "   2. Visit: ${GREEN}https://${FULL_DOMAIN}${NC}"
        echo -e "   3. Create your owner account (first user)"
        echo -e "   4. Set up your email and password"
        echo -e "   5. Start creating workflows!"
    fi
    echo ""
    
    echo -e "${BLUE}Useful Commands:${NC}"
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
    if [[ $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        echo -e "   docker exec n8n rclone ls gdrive:     # List Google Drive files"
    fi
    echo ""
    
    echo -e "${BLUE}Troubleshooting:${NC}"
    echo -e "   If n8n is not accessible:"
    echo -e "     • Wait 2-3 minutes for DNS propagation"
    echo -e "     • Check n8n: docker compose logs n8n"
    echo -e "     • Check tunnel: sudo journalctl -u cloudflared -f"
    echo -e "     • Verify DNS in Cloudflare dashboard"
    if [[ $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        echo -e "   If workflows are missing:"
        echo -e "     • Check encryption key matches backup"
        echo -e "     • Review import logs: docker compose logs n8n"
        echo -e "     • Manually check: docker exec n8n ls -la /home/node/.n8n"
    fi
    echo ""
    
    echo -e "${BLUE}Resources:${NC}"
    echo -e "   n8n Docs:       https://docs.n8n.io"
    echo -e "   Cloudflare:     https://dash.cloudflare.com"
    echo -e "   Community:      https://community.n8n.io"
    echo -e "   Rclone Docs:    https://rclone.org/docs/"
    echo ""
    
    if [[ $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        print_warning "IMPORTANT: Check your workflows and credentials after login"
        print_info "OAuth credentials may need to be reconfigured"
    else
        print_warning "IMPORTANT: Create your owner account now at https://${FULL_DOMAIN}"
        print_info "The first user to register will become the instance owner"
    fi
    echo ""
    
    echo -e "${GREEN}Thank you for installing n8n! Happy automating!${NC}"
    echo ""
}

# Main Installation Flow
main() {
    # ======================================================
    # USER INPUT SECTION
    # ======================================================
    print_header "n8n Raspberry Pi Setup — Configuration"

    echo ""
    print_info "Please enter the following configuration details:"
    echo ""

    read -p "Your domain (e.g., example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        print_error "Domain cannot be empty."
        read -p "Your domain (e.g., example.com): " DOMAIN
    done

    read -p "Subdomain for n8n (e.g., n8n): " SUBDOMAIN
    SUBDOMAIN=${SUBDOMAIN:-n8n}

    FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

    read -p "Timezone (default: Europe/Berlin): " TIMEZONE
    TIMEZONE=${TIMEZONE:-Europe/Berlin}

    read -p "Cloudflare Tunnel name (default: n8n-tunnel): " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-n8n-tunnel}

    echo ""
    read -p "Do you want to restore from a Google Drive backup? (y/N): " -n 1 -r RESTORE_BACKUP
    echo ""
    RESTORE_BACKUP=${RESTORE_BACKUP:-n}

    N8N_DIR="$HOME/n8n"

    print_header "Configuration Summary"
    echo -e "${BLUE}Domain:        ${GREEN}$DOMAIN${NC}"
    echo -e "${BLUE}Subdomain:     ${GREEN}$SUBDOMAIN${NC}"
    echo -e "${BLUE}Full Domain:   ${GREEN}$FULL_DOMAIN${NC}"
    echo -e "${BLUE}Tunnel Name:   ${GREEN}$TUNNEL_NAME${NC}"
    echo -e "${BLUE}Timezone:      ${GREEN}$TIMEZONE${NC}"
    echo -e "${BLUE}n8n Directory: ${GREEN}$N8N_DIR${NC}"
    echo -e "${BLUE}Restore Backup:${GREEN}$([[ $RESTORE_BACKUP =~ ^[Yy]$ ]] && echo 'Yes' || echo 'No')${NC}"
    echo ""
    read -p "Press Enter to confirm and continue, or Ctrl+C to cancel..."
    echo ""
    
    # ======================================================
    # INSTALLATION OVERVIEW
    # ======================================================
    
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
    
    echo -e "${BLUE}Installation Details:${NC}"
    echo -e "   Domain:              ${GREEN}https://${FULL_DOMAIN}${NC}"
    echo -e "   Installation Dir:    ${GREEN}${N8N_DIR}${NC}"
    echo -e "   Tunnel Name:         ${GREEN}${TUNNEL_NAME}${NC}"
    echo -e "   Timezone:            ${GREEN}${TIMEZONE}${NC}"
    echo ""
    
    echo -e "${BLUE}What will be installed:${NC}"
    echo -e "   [OK] Docker & Docker Compose"
    echo -e "   [OK] n8n workflow automation"
    echo -e "   [OK] Cloudflare Tunnel (cloudflared)"
    echo -e "   [OK] Automatic startup services"
    echo -e "   [OK] Backup script"
    if [[ $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        echo -e "   [OK] Rclone & backup restoration"
    fi
    echo ""
    
    echo -e "${YELLOW}Requirements:${NC}"
    echo -e "   • Active Cloudflare account"
    echo -e "   • Domain ${DOMAIN} added to Cloudflare"
    echo -e "   • Internet connection"
    echo -e "   • ~15-20 minutes of installation time"
    echo ""
    
    echo -e "${BLUE}Installation Steps (12 total):${NC}"
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
    if [[ $RESTORE_BACKUP =~ ^[Yy]$ ]]; then
        echo -e "   12. Install Rclone & restore backup from Google Drive"
    fi
    echo ""
    
    read -p "Press Enter to start installation or Ctrl+C to cancel..."
    echo ""
    
    print_info "Starting installation process..."
    
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
    install_rclone_and_restore
    print_summary
}

# Run main function
main
