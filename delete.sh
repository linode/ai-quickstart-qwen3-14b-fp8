#!/usr/bin/env bash

set -euo pipefail

#==============================================================================
# Delete Linode Instance
#
# Usage:
#   ./delete.sh <instance_id>                    # Run locally (from cloned repo)
#   bash <(curl -fsSL https://raw.githubusercontent.com/linode/ai-quickstart-qwen3-14b-fp8/main/delete.sh) <instance_id>
#
#==============================================================================

# Project name (used for paths, service names, labels, etc.)
readonly PROJECT_NAME="ai-quickstart-qwen3-14b-fp8"

# Get directory of this script (empty if running via curl pipe)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null || echo "")"

# Remote repository base URL for shared tools
TOOLS_RAW_BASE="https://raw.githubusercontent.com/linode/ai-quickstart-gpt-oss-20b/main"

# Temp directory for remote execution (will be cleaned up on exit)
REMOTE_TEMP_DIR=""

#==============================================================================
# Setup: Ensure required files exist (download if running remotely)
#==============================================================================
# _dl - Get file from local or download from remote
# Usage: path=$(_dl <local_dir> <file_path> <repo_base_url> <temp_dir>)
# Returns: path to file (local or downloaded), empty if download fails
_dl() {
    local ld="$1" fp="$2" url="$3" td="$4"
    [ -n "$ld" ] && [ -f "${ld}/${fp}" ] && { echo "${ld}/${fp}"; return; }
    local dest="${td}/${fp}"; mkdir -p "$(dirname "$dest")"
    echo "Downloading ${fp}..." >&2
    curl -fsSL "${url}/${fp}" -o "$dest" 2>/dev/null && echo "$dest"
}

_setup_required_files() {
    REMOTE_TEMP_DIR="${TMPDIR:-/tmp}/${PROJECT_NAME}-$$"

    # Download quickstart_tools.sh from tools repo (shared across projects)
    QUICKSTART_TOOLS_PATH=$(_dl "$SCRIPT_DIR" "script/quickstart_tools.sh" "$TOOLS_RAW_BASE" "$REMOTE_TEMP_DIR") || { echo "ERROR: Failed to get quickstart_tools.sh" >&2; exit 1; }

    export QUICKSTART_TOOLS_PATH
}

# Cleanup function for temp files
_cleanup_temp_files() {
    if [ -n "${REMOTE_TEMP_DIR:-}" ] && [ -d "$REMOTE_TEMP_DIR" ]; then
        rm -rf "$REMOTE_TEMP_DIR"
    fi
}

# Register cleanup on exit
trap _cleanup_temp_files EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Setup required files (download if needed)
_setup_required_files

# Source quickstart tools library
source "$QUICKSTART_TOOLS_PATH"

# Show usage (for -h flag)
show_usage() {
    echo ""
    print_msg "$YELLOW" "Usage:"
    echo "  ./delete.sh <instance_id>    Delete instance by ID"
    echo "  ./delete.sh -h               Show this help"
    echo ""
    exit 0
}

# Check for help flag
if [ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    show_usage
fi

# Show banner and explanation
show_banner
print_msg "$CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_msg "$BOLD" "                    Delete Linode Instance"
print_msg "$CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_msg "$YELLOW" "This script will:"
echo "  • Authenticate with your Linode/Akamai Cloud account"
echo "  • Verify the instance exists and show its details"
echo "  • Ask for confirmation before deletion"
echo "  • Delete the specified instance"
echo ""
print_msg "$CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for missing argument
if [ $# -lt 1 ]; then
    error_exit "Instance ID is required. Usage: ./delete.sh <instance_id>"
fi

INSTANCE_ID="$1"

# Validate instance ID is numeric
if ! [[ "$INSTANCE_ID" =~ ^[0-9]+$ ]]; then
    error_exit "Instance ID must be numeric: $INSTANCE_ID"
fi

sleep 5

#==============================================================================
# Step 1: Authentication
#==============================================================================
show_step "🔑 Step 1/3: Authentication"

info "Getting API token..."
TOKEN=$(get_linode_token) || error_exit "Failed to get API token"
echo ""

#==============================================================================
# Step 2: Verify Instance
#==============================================================================
show_step "📝 Step 2/3: Verify Instance"

info "Checking instance ${INSTANCE_ID}..."
INSTANCE_INFO=$(linode_api_call "/linode/instances/${INSTANCE_ID}" "$TOKEN" 2>/dev/null)

# Check if instance exists (API returns error object if not found)
if echo "$INSTANCE_INFO" | jq -e '.errors' > /dev/null 2>&1; then
    error_exit "Instance ${INSTANCE_ID} not found"
fi

INSTANCE_LABEL=$(echo "$INSTANCE_INFO" | jq -r '.label // empty')
if [ -z "$INSTANCE_LABEL" ]; then
    error_exit "Instance ${INSTANCE_ID} not found"
fi

INSTANCE_STATUS=$(echo "$INSTANCE_INFO" | jq -r '.status // "unknown"')
INSTANCE_REGION=$(echo "$INSTANCE_INFO" | jq -r '.region // "unknown"')
INSTANCE_TYPE=$(echo "$INSTANCE_INFO" | jq -r '.type // "unknown"')
INSTANCE_IP=$(echo "$INSTANCE_INFO" | jq -r '.ipv4[0] // "unknown"')

echo ""
warn "You are about to delete:"
echo "  Instance ID: $INSTANCE_ID"
echo "  Label: $INSTANCE_LABEL"
echo "  Status: $INSTANCE_STATUS"
echo "  Region: $INSTANCE_REGION"
echo "  Type: $INSTANCE_TYPE"
echo "  IP: $INSTANCE_IP"
echo ""

# Confirm deletion
read -p "$(echo -e ${YELLOW}Are you sure you want to delete this instance? [y/N]:${NC} )" confirm </dev/tty
confirm=${confirm:-N}

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Deletion cancelled"
    exit 0
fi

#==============================================================================
# Step 3: Delete Instance
#==============================================================================
show_step "💥 Step 3/3: Delete Instance"

info "Deleting instance ${INSTANCE_ID}..."
RESPONSE=$(linode_api_call "/linode/instances/${INSTANCE_ID}" "$TOKEN" "DELETE" 2>/dev/null) || error_exit "Failed to delete instance"

success "Instance ${INSTANCE_ID} (${INSTANCE_LABEL}) deleted successfully"
