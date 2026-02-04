#!/bin/bash
# OpenClaw Deploy - Prerequisite Checker
# Validates that all required tools and configurations are in place before deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

print_header() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         OpenClaw Deploy - Prerequisite Check             ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((ERRORS++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

check_info() {
    echo -e "  → $1"
}

# Check if a command exists
check_command() {
    local cmd=$1
    local install_hint=$2

    if command -v "$cmd" &> /dev/null; then
        local version=$($cmd --version 2>/dev/null | head -n1 || echo "unknown version")
        check_pass "$cmd installed ($version)"
        return 0
    else
        check_fail "$cmd not found"
        check_info "Install: $install_hint"
        return 1
    fi
}

# Check gcloud authentication
check_gcloud_auth() {
    echo ""
    echo "Checking Google Cloud SDK..."
    echo "─────────────────────────────"

    if ! command -v gcloud &> /dev/null; then
        check_fail "gcloud CLI not installed"
        check_info "Install: https://cloud.google.com/sdk/docs/install"
        return 1
    fi

    local version=$(gcloud --version 2>/dev/null | head -n1)
    check_pass "gcloud installed ($version)"

    # Check if authenticated
    local active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
    if [ -n "$active_account" ]; then
        check_pass "gcloud authenticated as: $active_account"
    else
        check_fail "gcloud not authenticated"
        check_info "Run: gcloud auth login"
        return 1
    fi

    return 0
}

# Check GCP project
check_gcp_project() {
    echo ""
    echo "Checking GCP Project..."
    echo "─────────────────────────────"

    local project="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

    if [ -z "$project" ]; then
        check_fail "No GCP project configured"
        check_info "Set: export GCP_PROJECT_ID=your-project-id"
        check_info "Or: gcloud config set project your-project-id"
        return 1
    fi

    check_pass "GCP project: $project"

    # Verify project access
    if gcloud projects describe "$project" &>/dev/null; then
        check_pass "Project access verified"
    else
        check_fail "Cannot access project: $project"
        check_info "Ensure you have permissions and the project exists"
        return 1
    fi

    return 0
}

# Check Compute Engine API
check_compute_api() {
    echo ""
    echo "Checking Compute Engine API..."
    echo "─────────────────────────────"

    local project="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

    if [ -z "$project" ]; then
        check_warn "Cannot check API - no project configured"
        return 1
    fi

    if gcloud services list --enabled --project="$project" 2>/dev/null | grep -q "compute.googleapis.com"; then
        check_pass "Compute Engine API enabled"
    else
        check_fail "Compute Engine API not enabled"
        check_info "Enable: gcloud services enable compute.googleapis.com --project=$project"
        return 1
    fi

    return 0
}

# Check Ansible
check_ansible() {
    echo ""
    echo "Checking Ansible..."
    echo "─────────────────────────────"

    if ! command -v ansible &> /dev/null; then
        check_fail "ansible not installed"
        check_info "Install: pip install ansible"
        check_info "Or: brew install ansible"
        return 1
    fi

    local version=$(ansible --version 2>/dev/null | head -n1)
    check_pass "ansible installed ($version)"

    # Check ansible-playbook
    if command -v ansible-playbook &> /dev/null; then
        check_pass "ansible-playbook available"
    else
        check_fail "ansible-playbook not found"
        return 1
    fi

    # Check ansible-galaxy
    if command -v ansible-galaxy &> /dev/null; then
        check_pass "ansible-galaxy available"
    else
        check_warn "ansible-galaxy not found (needed for collections)"
    fi

    # Check version (2.14+ recommended)
    local version_num=$(ansible --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    local major=$(echo "$version_num" | cut -d. -f1)
    local minor=$(echo "$version_num" | cut -d. -f2)

    if [ "$major" -ge 2 ] && [ "$minor" -ge 14 ]; then
        check_pass "Ansible version $version_num meets requirements (2.14+)"
    else
        check_warn "Ansible version $version_num - recommend 2.14+"
    fi

    return 0
}

# Check optional tools
check_optional_tools() {
    echo ""
    echo "Checking Optional Tools..."
    echo "─────────────────────────────"

    # GPG for encrypted backups
    if command -v gpg &> /dev/null; then
        check_pass "gpg available (for encrypted backups)"
    else
        check_warn "gpg not installed (encrypted backups disabled)"
        check_info "Install: brew install gnupg  OR  apt install gnupg"
    fi

    # SSH
    if command -v ssh &> /dev/null; then
        check_pass "ssh available"
    else
        check_fail "ssh not found"
    fi
}

# Check deployment directory
check_deployment_dir() {
    echo ""
    echo "Checking Project Structure..."
    echo "─────────────────────────────"

    if [ -f "ansible/playbook.yml" ]; then
        check_pass "ansible/playbook.yml found"
    else
        check_fail "ansible/playbook.yml not found"
        check_info "Run this script from the OpenClawDeploy root directory"
        return 1
    fi

    if [ -f "ansible/requirements.yml" ]; then
        check_pass "ansible/requirements.yml found"
    else
        check_warn "ansible/requirements.yml not found"
    fi

    if [ -f "scripts/manage_deployment.sh" ]; then
        check_pass "scripts/manage_deployment.sh found"
    else
        check_fail "scripts/manage_deployment.sh not found"
    fi

    # Check for inventory directory (optional)
    if [ -d "inventory" ]; then
        local inv_count=$(ls -1 inventory/*.ini 2>/dev/null | wc -l)
        check_pass "inventory/ directory exists ($inv_count instance(s))"
    else
        check_info "inventory/ directory not found (will be created on first deployment)"
    fi

    return 0
}

# Print summary
print_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "                        SUMMARY"
    echo "═══════════════════════════════════════════════════════════"

    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}All checks passed! You're ready to deploy.${NC}"
        echo ""
        echo "Next steps:"
        echo "  1. ./scripts/manage_deployment.sh create <vm-name>"
        echo "  2. Edit deployments/<vm-name>/vars.yml (optional)"
        echo "  3. ./scripts/manage_deployment.sh update <vm-name>"
        return 0
    elif [ $ERRORS -eq 0 ]; then
        echo -e "${YELLOW}Passed with $WARNINGS warning(s).${NC}"
        echo "You can proceed, but review warnings above."
        return 0
    else
        echo -e "${RED}Failed with $ERRORS error(s) and $WARNINGS warning(s).${NC}"
        echo "Please fix the errors above before deploying."
        return 1
    fi
}

# Main
main() {
    print_header

    check_gcloud_auth
    check_gcp_project
    check_compute_api
    check_ansible
    check_optional_tools
    check_deployment_dir

    print_summary
    exit $ERRORS
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
