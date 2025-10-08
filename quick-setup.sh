#!/bin/bash

# Quick Setup Script for n8n Installation
# This script helps you configure .env interactively

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}n8n Quick Setup${NC}"
echo -e "${BLUE}================================${NC}\n"

# Copy example env
cp .env.example .env

# Interactive configuration
echo -e "${YELLOW}Configuration Setup${NC}\n"

# Domain
read -p "Domain (default: devk061.de): " domain
domain=${domain:-devk061.de}
sed -i "s/DOMAIN=\".*\"/DOMAIN=\"$domain\"/" .env

# Subdomain
read -p "Subdomain (default: n8n): " subdomain
subdomain=${subdomain:-n8n}
sed -i "s/SUBDOMAIN=\".*\"/SUBDOMAIN=\"$subdomain\"/" .env

# Timezone
read -p "Timezone (default: Europe/Berlin): " timezone
timezone=${timezone:-Europe/Berlin}
sed -i "s|TIMEZONE=\".*\"|TIMEZONE=\"$timezone\"|" .env

# Google Drive Folder ID
echo ""
echo -e "${BLUE}Google Drive Folder ID:${NC}"
echo "Get this from your folder URL:"
echo "https://drive.google.com/drive/folders/YOUR_FOLDER_ID_HERE"
echo ""
read -p "Enter Google Drive Folder ID (or leave empty to skip): " folder_id
sed -i "s/GOOGLE_DRIVE_FOLDER_ID=\".*\"/GOOGLE_DRIVE_FOLDER_ID=\"$folder_id\"/" .env

# Make scripts executable (check if they exist first)
if [ -f "install-n8n.sh" ]; then
    chmod +x install-n8n.sh
fi

if [ -f "import-workflows.sh" ]; then
    chmod +x import-workflows.sh
fi

echo ""
echo -e "${GREEN}✓ Configuration complete!${NC}\n"

echo -e "${BLUE}Your settings:${NC}"
echo -e "  Domain: ${GREEN}${subdomain}.${domain}${NC}"
echo -e "  Timezone: ${GREEN}${timezone}${NC}"
if [ ! -z "$folder_id" ]; then
    echo -e "  Google Drive Folder: ${GREEN}${folder_id}${NC}"
fi

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review .env if needed: ${BLUE}nano .env${NC}"
echo "  2. Run installation: ${BLUE}./install-n8n.sh${NC}"
echo "  3. After setup, import workflows: ${BLUE}./import-workflows.sh${NC}"
echo ""

if [ -f "install-n8n.sh" ]; then
    read -p "Start installation now? (Y/n): " start_now
    if [[ ! $start_now =~ ^[Nn]$ ]]; then
        echo ""
        ./install-n8n.sh
    fi
else
    echo -e "${YELLOW}Note: install-n8n.sh not found in current directory${NC}"
    echo "Make sure you're running this from the cloned repository"
fi