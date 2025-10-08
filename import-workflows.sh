#!/bin/bash

# n8n Workflow Importer from Google Drive Folder
# This script downloads all workflow JSON files from a Google Drive folder
# and imports them into n8n

set -e

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load configuration
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found!"
    exit 1
fi

source "$SCRIPT_DIR/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check if n8n is running
    if ! docker ps | grep -q n8n; then
        print_error "n8n container is not running!"
        print_info "Start n8n with: cd ~/n8n && docker compose up -d"
        exit 1
    fi
    
    print_success "n8n is running"
    
    # Check if GOOGLE_DRIVE_FOLDER_ID is set
    if [ -z "$GOOGLE_DRIVE_FOLDER_ID" ]; then
        print_error "GOOGLE_DRIVE_FOLDER_ID is not set in .env file"
        print_info "Please add your Google Drive folder ID to the .env file"
        exit 1
    fi
    
    print_success "Google Drive folder ID configured"
}

install_gdown() {
    print_header "Installing gdown (Google Drive downloader)"
    
    if command -v gdown &> /dev/null; then
        print_success "gdown is already installed"
        return
    fi
    
    print_info "Installing gdown via pip..."
    
    # Check if pip3 is installed
    if ! command -v pip3 &> /dev/null; then
        print_info "Installing python3-pip..."
        sudo apt update
        sudo apt install -y python3-pip
    fi
    
    pip3 install gdown
    
    print_success "gdown installed"
}

download_workflows() {
    print_header "Downloading Workflows from Google Drive"
    
    TEMP_DIR="/tmp/n8n-workflows-import"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    print_info "Downloading folder: $GOOGLE_DRIVE_FOLDER_ID"
    
    # Download entire folder from Google Drive
    cd "$TEMP_DIR"
    
    if gdown --folder "https://drive.google.com/drive/folders/$GOOGLE_DRIVE_FOLDER_ID" 2>&1 | tee /tmp/gdown.log; then
        print_success "Files downloaded"
    else
        print_error "Failed to download from Google Drive"
        print_info "Make sure the folder is publicly accessible or you're authenticated"
        
        # Check if it's a permission issue
        if grep -q "Permission denied" /tmp/gdown.log || grep -q "access denied" /tmp/gdown.log; then
            print_warning "The folder may not be publicly accessible"
            echo ""
            echo "To fix this:"
            echo "1. Open your Google Drive folder"
            echo "2. Click 'Share' button"
            echo "3. Change to 'Anyone with the link can view'"
            echo "4. Try running this script again"
        fi
        
        exit 1
    fi
    
    # Count JSON files
    JSON_COUNT=$(find "$TEMP_DIR" -name "*.json" -type f | wc -l)
    
    if [ "$JSON_COUNT" -eq 0 ]; then
        print_warning "No JSON files found in the downloaded folder"
        exit 1
    fi
    
    print_success "Found $JSON_COUNT JSON workflow file(s)"
}

import_workflows() {
    print_header "Importing Workflows into n8n"
    
    TEMP_DIR="/tmp/n8n-workflows-import"
    IMPORTED=0
    FAILED=0
    
    # Find all JSON files recursively
    while IFS= read -r workflow_file; do
        filename=$(basename "$workflow_file")
        print_info "Importing: $filename"
        
        # Validate if it's a valid n8n workflow
        if ! grep -q '"nodes"' "$workflow_file" 2>/dev/null; then
            print_warning "Skipping $filename - not a valid n8n workflow"
            ((FAILED++))
            continue
        fi
        
        # Copy file into container
        if docker cp "$workflow_file" n8n:/tmp/workflow-import.json; then
            # Import using n8n CLI
            if docker exec n8n n8n import:workflow --input=/tmp/workflow-import.json 2>/dev/null; then
                print_success "Imported: $filename"
                ((IMPORTED++))
            else
                print_error "Failed to import: $filename"
                ((FAILED++))
            fi
        else
            print_error "Failed to copy: $filename"
            ((FAILED++))
        fi
        
        # Small delay between imports
        sleep 1
        
    done < <(find "$TEMP_DIR" -name "*.json" -type f)
    
    echo ""
    print_success "Import Summary:"
    echo -e "  ${GREEN}Successfully imported: $IMPORTED${NC}"
    
    if [ "$FAILED" -gt 0 ]; then
        echo -e "  ${RED}Failed: $FAILED${NC}"
    fi
}

cleanup() {
    print_header "Cleaning Up"
    
    rm -rf /tmp/n8n-workflows-import
    rm -f /tmp/gdown.log
    
    print_success "Temporary files cleaned up"
}

restart_n8n() {
    print_header "Restarting n8n"
    
    cd "$N8N_DIR"
    docker compose restart
    
    sleep 5
    
    print_success "n8n restarted"
}

print_final_summary() {
    print_header "Workflow Import Complete! 🎉"
    
    echo -e "${GREEN}All workflows have been imported into n8n${NC}\n"
    
    echo -e "${BLUE}Next Steps:${NC}"
    echo -e "  1. Visit your n8n instance"
    echo -e "  2. Log in with your account"
    echo -e "  3. Your workflows should now be visible\n"
    
    echo -e "${YELLOW}Note:${NC} If workflows don't appear immediately, try:"
    echo -e "  • Refreshing the page"
    echo -e "  • Logging out and back in"
    echo -e "  • Checking: cd ~/n8n && docker compose logs\n"
}

# Main execution
main() {
    clear
    print_header "n8n Workflow Importer - Google Drive"
    
    echo -e "Google Drive Folder ID: ${GREEN}${GOOGLE_DRIVE_FOLDER_ID}${NC}"
    echo -e "n8n Directory: ${GREEN}${N8N_DIR}${NC}\n"
    
    read -p "Press Enter to start import or Ctrl+C to cancel..."
    
    check_prerequisites
    install_gdown
    download_workflows
    import_workflows
    cleanup
    restart_n8n
    print_final_summary
}

# Run main function
main