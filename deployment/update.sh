#!/bin/bash
set -e

# Update script for OpenClaw Ansible Playbook
# This script pulls the latest changes from git and runs the playbook

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔄 Checking for updates...${NC}"

# Check if we are in a git repository
if [ -d ".git" ]; then
    echo "Git repository detected."
    
    # Check for local changes
    if ! git diff-index --quiet HEAD --; then
        echo -e "${YELLOW}⚠️  Warning: You have local changes in this repository.${NC}"
        read -p "Do you want to stash them and continue update? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Stashing changes..."
            git stash
        else
            echo "Update aborted. Please handle local changes manually."
            exit 1
        fi
    fi

    echo "Pulling latest changes..."
    git pull
    
    echo -e "${GREEN}✅ Update complete.${NC}"
    echo ""
    echo "Running playbook..."
    ./run-playbook.sh "$@"
else
    echo -e "${RED}❌ Error: Not a git repository.${NC}"
    echo "This script only works if you installed via git clone."
    echo "If you downloaded a zip, please download the latest version manually."
    exit 1
fi
