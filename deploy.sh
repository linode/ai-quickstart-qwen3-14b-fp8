#!/usr/bin/env bash

set -euo pipefail

#==============================================================================
# Akamai Cloud (Linode) GPU Instance Setup Script
#
# This script automates the creation of a GPU instance with vLLM and Open-WebUI
#
# Usage:
#   ./deploy.sh                    # Run locally (from cloned repo)
#   bash <(curl -fsSL https://raw.githubusercontent.com/linode/ai-quickstart-qwen3-14b-fp8/main/deploy.sh)
#
#==============================================================================

# Project name (used for paths, service names, labels, etc.)
readonly PROJECT_NAME="ai-quickstart-qwen3-14b-fp8"

# Get directory of this script (empty if running via curl pipe)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null || echo "")"
ORIGINAL_SCRIPT_DIR="$SCRIPT_DIR"

# Remote repository base URLs (for downloading files when running remotely)
REPO_RAW_BASE="https://raw.githubusercontent.com/linode/${PROJECT_NAME}/main"
TOOLS_RAW_BASE="https://raw.githubusercontent.com/linode/ai-quickstart-gpt-oss-20b/main"

# Temp directory for remote execution (will be cleaned up on exit)
REMOTE_TEMP_DIR=""

#==============================================================================
# Setup: Ensure required files exist (download if running remotely)
#==============================================================================
# _dl - Get file from local or download from remote
# Usage: path=$(_dl <local_dir> <file_path> <repo_base_url> <temp_dir> [silent])
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

    QUICKSTART_TOOLS_PATH=$(_dl "$SCRIPT_DIR" "script/quickstart_tools.sh" "$TOOLS_RAW_BASE" "$REMOTE_TEMP_DIR") || { echo "ERROR: Failed to get quickstart_tools.sh" >&2; exit 1; }
    local f; for f in cloud-init.yaml docker-compose.yml install.sh Caddyfile; do
        _dl "$SCRIPT_DIR" "template/$f" "$REPO_RAW_BASE" "$REMOTE_TEMP_DIR" >/dev/null || { echo "ERROR: Failed to get $f" >&2; exit 1; }
    done
    TEMPLATE_DIR="${SCRIPT_DIR}/template"; [ -d "$TEMPLATE_DIR" ] && [ -f "$TEMPLATE_DIR/cloud-init.yaml" ] || TEMPLATE_DIR="${REMOTE_TEMP_DIR}/template"

    export QUICKSTART_TOOLS_PATH TEMPLATE_DIR
}

# Cleanup function for temp files
_cleanup_temp_files() {
    if [ -n "${REMOTE_TEMP_DIR:-}" ] && [ -d "$REMOTE_TEMP_DIR" ]; then
        rm -rf "$REMOTE_TEMP_DIR"
    fi
}

# Register cleanup on exit (EXIT handles normal exit and will also run after INT/TERM)
trap _cleanup_temp_files EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Setup required files (download if needed)
_setup_required_files

# Source quickstart tools library
source "$QUICKSTART_TOOLS_PATH"

# Log file setup
LOG_FILE="${SCRIPT_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

# Colors and API_BASE are now exported by quickstart_tools.sh
# RED, GREEN, YELLOW, BLUE, CYAN, NC, MAGENTA, BOLD, API_BASE

# Global variables
TOKEN=""
INSTANCE_LABEL=""
INSTANCE_PASSWORD=""
SSH_PUBLIC_KEY=""
SELECTED_REGION=""
SELECTED_TYPE=""
INSTANCE_IP=""
INSTANCE_ID=""

#==============================================================================
# Local Helper Functions (extended from quickstart_tools)
#==============================================================================

# Print error and exit (with instance deletion option)
# This extends error_exit with instance cleanup capability
_error_exit_with_cleanup() {
    local message="$1"
    local offer_delete="${2:-false}"

    print_msg "$RED" "❌ ERROR: $message"
    log_to_file "ERROR" "$message"

    # Offer to delete instance if requested and instance was created
    if [ "$offer_delete" = "true" ] && [ -n "${INSTANCE_ID:-}" ]; then
        echo ""
        printf '\n\n\n\033[3A'        # Print 3 blank lines to scroll up
        read -p "$(echo -e ${YELLOW}Do you want to delete the failed instance? [Y/n]:${NC} )" delete_choice </dev/tty
        delete_choice=${delete_choice:-Y}

        if [[ "$delete_choice" =~ ^[Yy]$ ]]; then
            echo ""
            print_msg "$YELLOW" "Deleting instance (ID: ${INSTANCE_ID})..."

            if delete_instance "$TOKEN" "$INSTANCE_ID" > /dev/null; then
                success "Instance deleted successfully"
            else
                warn "Failed to delete instance. You may need to delete it manually from the Linode Cloud Manager"
                info "Instance ID: ${INSTANCE_ID}"
            fi
        else
            info "Instance was not deleted. You can manage it from the Linode Cloud Manager"
            info "Instance ID: ${INSTANCE_ID}"
        fi
    fi

    exit 1
}

#==============================================================================
# Show Logo
#==============================================================================
show_banner

print_msg "$CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_msg "$BOLD" "          AI Quickstart Qwen3-14B-FP8 LLM"
print_msg "$CYAN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_msg "$YELLOW" "Deploys a GPU instance with vLLM, Open-WebUI, and Qwen3-14B-FP8 model (~10-15 min)"
echo ""

# before proceeding, ensure jq is installed
ensure_jq || error_exit "jq is required but could not be installed automatically. Please install jq and re-run the script."

sleep 4

#==============================================================================
# Get Token from linode-cli or Linode OAuth
#==============================================================================
show_step "🔑 Step 1/10: Obtaining Linode API token..."

# Get token using quickstart_tools (env → linode-cli → OAuth)
TOKEN=$(get_linode_token) || error_exit "Failed to get API token. Please configure linode-cli or set LINODE_TOKEN"
echo ""

#==============================================================================
# Get GPU Availability
#==============================================================================
show_step "📊 Step 2/10: Fetching GPU availability..."

GPU_DATA=$(get_gpu_availability "$TOKEN") || error_exit "Failed to fetch GPU availability data"

success "GPU availability data fetched successfully"
echo ""

#==============================================================================
# Let User Select Region
#==============================================================================
show_step "🌍 Step 3/10: Select Region"

# Get available regions using quickstart_tools
get_available_regions "$GPU_DATA" REGION_LIST REGION_DATA

if [ ${#REGION_LIST[@]} -eq 0 ]; then
    error_exit "No regions with available GPU instances found"
fi

print_msg "$GREEN" "Available Regions:"

# Use ask_selection for region choice
ask_selection "Select a region" REGION_LIST "" region_choice

# Get full region info from the data array using the selection index
IFS='|' read -r SELECTED_REGION region_label available_instance_types <<< "${REGION_DATA[$((region_choice-1))]}"

echo "Selected region: $SELECTED_REGION ($region_label)"
log_to_file "INFO" "User selected region: $SELECTED_REGION ($region_label)"
echo ""

#==============================================================================
# Let User Select Instance Type
#==============================================================================
show_step "💻 Step 4/10: Select Instance Type"

print_msg "$GREEN" "Available Instance Types in $SELECTED_REGION:"

# Get available instance types for selected region using quickstart_tools
get_gpu_details "$GPU_DATA" "$available_instance_types" "g2-gpu-rtx4000a1-s" TYPE_DISPLAY TYPE_DATA default_type_index

if [ ${#TYPE_DISPLAY[@]} -eq 0 ]; then
    error_exit "No GPU instance available in selected region"
fi

# Use ask_selection for instance type choice
ask_selection "Select an instance type" TYPE_DISPLAY "$default_type_index" type_choice "\n     ${YELLOW}⭐ RECOMMENDED${NC}"

# Extract the actual type ID from the selected option
SELECTED_TYPE=$(echo "${TYPE_DATA[$((type_choice-1))]}" | jq -r '.id')

echo "Selected instance type: $SELECTED_TYPE"
log_to_file "INFO" "User selected instance type: $SELECTED_TYPE"
echo ""

#==============================================================================
# Let User Specify Instance Label
#==============================================================================
show_step "🏷️  Step 5/10: Instance Label"

INSTANCE_LABEL="${PROJECT_NAME}-$(date +%y%m%d%H%M)"
print_msg "$GREEN" "Your Instance Label: $INSTANCE_LABEL"
echo ""

scroll_up
read -p "$(echo -e ${YELLOW}Use this instance label? [Y/n]:${NC} )" confirm </dev/tty
[[ "${confirm:-Y}" =~ ^[Yy]$ ]] || ask_input "Enter instance label" "$INSTANCE_LABEL" "validate_instance_label" "❌ Invalid label format" INSTANCE_LABEL

echo "Instance label: $INSTANCE_LABEL"
log_to_file "INFO" "User set instance label: $INSTANCE_LABEL"
echo ""

#==============================================================================
# Let User Specify Root Password
#==============================================================================
show_step "🔐 Step 6/10: Root Password"
print_msg "$GREEN" "A root password is required for secure access to the instance"
echo ""

ask_password INSTANCE_PASSWORD
echo ""

#==============================================================================
# Let User Select SSH Public Key
#==============================================================================
show_step "🔑 Step 7/10: SSH Public Key (Required)"
print_msg "$GREEN" "An SSH key is required for secure access to the instance"
echo ""

# Get SSH keys using quickstart_tools
get_ssh_keys SSH_KEY_DISPLAY SSH_KEY_PATHS

# Check if there are existing SSH keys
auto_generate_ssh=false
if [ ${#SSH_KEY_PATHS[@]} -eq 0 ]; then
    info "No existing SSH keys found in ~/.ssh/"
    scroll_up
    read -p "$(echo -e ${YELLOW}Generate a new SSH key pair? [Y/n]:${NC} )" confirm </dev/tty
    [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || error_exit "SSH key is required. Please add an SSH key to ~/.ssh/ and try again."
    auto_generate_ssh=true
else
    ask_selection "Select an SSH key" SSH_KEY_DISPLAY "" key_choice
    [ "$key_choice" -gt ${#SSH_KEY_PATHS[@]} ] && auto_generate_ssh=true
fi

if [ "$auto_generate_ssh" = true ]; then
    AUTO_KEY_PATH="$HOME/.ssh/${INSTANCE_LABEL}"
    SSH_PUBLIC_KEY=$(generate_ssh_key "$AUTO_KEY_PATH" "$(basename "$AUTO_KEY_PATH")") || error_exit "Failed to generate SSH key"
    SSH_KEY_PATHS+=("${AUTO_KEY_PATH}.pub")
    key_choice=${#SSH_KEY_PATHS[@]}
    log_to_file "INFO" "Auto-generated SSH key: ${AUTO_KEY_PATH}"
    success "Generated new SSH key: ${AUTO_KEY_PATH}"
    warn "IMPORTANT: Save the private key securely!"
else
    SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATHS[$((key_choice-1))]}")
    log_to_file "INFO" "User selected SSH key: $(basename "${SSH_KEY_PATHS[$((key_choice-1))]}")"
    echo "Selected SSH key: $(basename "${SSH_KEY_PATHS[$((key_choice-1))]}")"
fi
SSH_KEY_FILE="${SSH_KEY_PATHS[$((key_choice-1))]%.pub}"
SSH_KEY_NAME="$(basename "${SSH_KEY_PATHS[$((key_choice-1))]}")"
echo ""

#==============================================================================
# Create Cloud-Init with Base64 Encoded Files
#==============================================================================

# Base64 encode docker-compose.yml
if [ ! -f "${TEMPLATE_DIR}/docker-compose.yml" ]; then
    error_exit "template/docker-compose.yml not found"
fi
DOCKER_COMPOSE_BASE64=$(base64 < "${TEMPLATE_DIR}/docker-compose.yml" | tr -d '\n')

# Base64 encode Caddyfile
if [ ! -f "${TEMPLATE_DIR}/Caddyfile" ]; then
    error_exit "template/Caddyfile not found"
fi
CADDYFILE_BASE64=$(base64 < "${TEMPLATE_DIR}/Caddyfile" | tr -d '\n')

# Base64 encode install.sh (need to add notify function)
if [ ! -f "${TEMPLATE_DIR}/install.sh" ]; then
    error_exit "template/install.sh not found"
fi
INSTALL_SH_BASE64=$(base64 < "${TEMPLATE_DIR}/install.sh" | tr -d '\n')

# Read cloud-init template
if [ ! -f "${TEMPLATE_DIR}/cloud-init.yaml" ]; then
    error_exit "template/cloud-init.yaml not found"
fi

# Create temporary cloud-init file with replacements
CLOUD_INIT_DATA=$(cat "${TEMPLATE_DIR}/cloud-init.yaml" | \
    sed "s|_PROJECT_NAME_PLACEHOLDER_|${PROJECT_NAME}|g" | \
    sed "s|_INSTANCE_LABEL_PLACEHOLDER_|${INSTANCE_LABEL}|g" | \
    sed "s|_CADDYFILE_BASE64_CONTENT_PLACEHOLDER_|${CADDYFILE_BASE64}|g" | \
    sed "s|_DOCKER_COMPOSE_BASE64_CONTENT_PLACEHOLDER_|${DOCKER_COMPOSE_BASE64}|g" | \
    sed "s|_INSTALL_SH_BASE64_CONTENT_PLACEHOLDER_|${INSTALL_SH_BASE64}|g")

#==============================================================================
# Show Confirmation Prompt
#==============================================================================
show_step "📝 Step 8/10: Confirmation ..."

UBUNTU_IMAGE="linode/ubuntu24.04"

info "Instance configuration:"
echo "  Region: $SELECTED_REGION"
echo "  Type: $SELECTED_TYPE"
echo "  Label: $INSTANCE_LABEL"
echo "  Image: $UBUNTU_IMAGE"
echo "  SSH Key: $SSH_KEY_NAME"
echo ""

# Ask for confirmation
scroll_up
read -p "$(echo -e ${YELLOW}Proceed with instance creation? [Y/n]:${NC} )" confirm </dev/tty
confirm=${confirm:-Y}

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    warn "Instance creation cancelled by user"
    exit 0
fi
echo ""

#==============================================================================
# Create Instance via Linode API
#==============================================================================
show_step "🚀 Step 9/10: Creating instance ..."
scroll_up

# Encode cloud-init as base64
USER_DATA_BASE64=$(echo "$CLOUD_INIT_DATA" | base64 | tr -d '\n')

# Create instance using quickstart_tools
log_to_file "INFO" "API Request: POST /linode/instances"
log_to_file "INFO" "Request payload: label=$INSTANCE_LABEL, region=$SELECTED_REGION, type=$SELECTED_TYPE, image=$UBUNTU_IMAGE"

CREATE_RESPONSE=$(create_instance "$TOKEN" "$INSTANCE_LABEL" "$SELECTED_REGION" "$SELECTED_TYPE" \
    "$UBUNTU_IMAGE" "$INSTANCE_PASSWORD" "$SSH_PUBLIC_KEY" "$USER_DATA_BASE64")

log_to_file "INFO" "API Response: $CREATE_RESPONSE"

# Check for errors
if echo "$CREATE_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    error_exit "Failed to create instance: $(echo "$CREATE_RESPONSE" | jq -r '.errors[0].reason')"
fi

INSTANCE_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id')
INSTANCE_IP=$(echo "$CREATE_RESPONSE" | jq -r '.ipv4[0]')

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    error_exit "Failed to create instance: Invalid response"
fi

log_to_file "INFO" "Instance created: ID=$INSTANCE_ID, IP=$INSTANCE_IP, Label=$INSTANCE_LABEL"

info "Instance created successfully, starting up..."
echo "  Instance ID: $INSTANCE_ID"
echo "  IP Address: $INSTANCE_IP"
echo ""

#==============================================================================
# Wait for Instance to be Ready
#==============================================================================
show_step "⏳ Step 10: Monitoring Deployment ..."
scroll_up 8

#------------------------------------------------------------------------------
# Phase 1: Wait for instance status to become "running" (max 3 minutes)
#------------------------------------------------------------------------------
print_msg "$YELLOW" "Waiting instance to boot up ... (this may take 2 - 3 minutes)"
START_TIME=$(date +%s)
TIMEOUT=180

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    ELAPSED_STR=$([ $ELAPSED -ge 60 ] && echo "$((ELAPSED / 60))m $((ELAPSED % 60))s" || echo "${ELAPSED}s")

    STATUS=$(linode_api_call "/linode/instances/${INSTANCE_ID}" "$TOKEN" | jq -r '.status')
    [ "$STATUS" = "running" ] && break
    [ $ELAPSED -ge $TIMEOUT ] && break
    
    progress "$YELLOW" "Status: ${STATUS:-unknown} - Elapsed: ${ELAPSED_STR}"
    sleep 5
done

[ "$STATUS" != "running" ] && _error_exit_with_cleanup "Instance failed to reach 'running' status" true
log_to_file "INFO" "Instance status reached 'running' in ${ELAPSED_STR}"
progress "$NC" "Instance is now in running status (took ${ELAPSED_STR})"
echo ""
echo ""

#------------------------------------------------------------------------------
# Phase 2: Waiting for cloud-init to finish package install (max 3 minutes)
#------------------------------------------------------------------------------
print_msg "$YELLOW" "Waiting cloud-init to finish installing required packages ... (this may take 3 - 5 minutes)"
scroll_up 8
START_TIME=$(date +%s)

# Start ntfy.sh JSON stream monitor
# Wait up to 180s for first message event, then continue until "Rebooting" or "Starting"
# Use --no-buffer to disable buffering
exec 3< <(curl -sN "https://ntfy.sh/${INSTANCE_LABEL}/json")

# Wait for first message event with 300s timeout
while IFS= read -t 300 -r line <&3; do
    event=$(echo "$line" | jq -r '.event // empty')
    [ "$event" = "message" ] && break
done || {
    exec 3<&-
    _error_exit_with_cleanup "Timeout: No cloud-init progress for 300 seconds" true
}

# Process first message and continue until termination keyword found
while true; do
    message=$(echo "$line" | jq -r '.message // empty')
    [ -n "$message" ] && {
        echo "$message" >&2
        echo "$message" | grep -qE "(Rebooting|Starting)" && break
    }

    IFS= read -r line <&3 || break
    [ "$(echo "$line" | jq -r '.event // empty')" = "message" ] || continue
done

exec 3<&-
ELAPSED=$(($(date +%s) - START_TIME))
log_to_file "INFO" "Cloud-init package installation completed"
echo -e "cloud-init process completed (took $([ $ELAPSED -ge 60 ] && echo "$((ELAPSED / 60))m $((ELAPSED % 60))s" || echo "${ELAPSED}s"))"
echo ""

# Wait 5 seconds for reboot to initiate
sleep 5

#------------------------------------------------------------------------------
# Phase 3: Wait for Instance to reboot (max 2 minutes)
#------------------------------------------------------------------------------
print_msg "$YELLOW" "Waiting for Instance to reboot... (this may take 1 - 2 minutes)"
scroll_up 8
START_TIME=$(date +%s)

# Setup SSH command with options to suppress warnings
SSH_OPTS=(-o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$SSH_KEY_FILE")

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    ELAPSED_STR=$([ $ELAPSED -ge 60 ] && echo "$((ELAPSED / 60))m $((ELAPSED % 60))s" || echo "${ELAPSED}s")
    progress "$YELLOW" "Status: booting ... Elapsed: ${ELAPSED_STR}"

    [ $ELAPSED -ge 120 ] && _error_exit_with_cleanup "Instance failed to become accessible" true
    ssh "${SSH_OPTS[@]}" "root@${INSTANCE_IP}" exit </dev/null 2>/dev/null && break
    sleep 2
done
log_to_file "INFO" "Instance rebooted and SSH accessible in ${ELAPSED_STR}s"
progress "$NC" "Instance is now running status. (took ${ELAPSED_STR})"
echo ""
echo ""

#------------------------------------------------------------------------------
# Phase 4: Verify Containers are Running
#------------------------------------------------------------------------------
print_msg "$YELLOW" "Waiting for containers to start..."
scroll_up 8

CONTAINER_CHECK=$(ssh "${SSH_OPTS[@]}" "root@${INSTANCE_IP}" "docker ps --format '{{.Names}}'" </dev/null 2>/dev/null || echo "")

if echo "$CONTAINER_CHECK" | grep -q "vllm" && echo "$CONTAINER_CHECK" | grep -q "open-webui" && echo "$CONTAINER_CHECK" | grep -q "caddy"; then
    log_to_file "INFO" "Docker containers verified: vLLM, Open-WebUI, and Caddy running"
    echo "All containers are running (vLLM, Open-WebUI, Caddy)"
else
    log_to_file "WARN" "Container check incomplete: $CONTAINER_CHECK"
    warn "Some containers may still be starting. Check manually with: docker ps"
fi
echo ""

print_msg "$YELLOW" "Waiting for Open-WebUI to be ready..."
scroll_up 8
START_TIME=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    ELAPSED_STR=$([ $ELAPSED -ge 60 ] && echo "$((ELAPSED / 60))m $((ELAPSED % 60))s" || echo "${ELAPSED}s")
    progress "$YELLOW" "Status: starting ... Elapsed: ${ELAPSED_STR}"

    if [ "$(ssh "${SSH_OPTS[@]}" "root@${INSTANCE_IP}" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/health" </dev/null 2>/dev/null || echo "000")" = "200" ]; then
        log_to_file "INFO" "Open-WebUI health check passed in ${ELAPSED}s"
        progress "$NC" "Open-WebUI is ready (took ${ELAPSED_STR})"
        break
    fi
    if [ $ELAPSED -ge 30 ]; then
        log_to_file "WARN" "Open-WebUI health check timeout after ${ELAPSED_STR}"
        warn "Timeout waiting for Open-WebUI health check. It may still be starting up."
        break
    fi
    sleep 2
done
echo ""
echo ""

print_msg "$YELLOW" "Waiting for vLLM to download Qwen3-14B-FP8 model... (this may take 3-5 minutes)"
scroll_up 8
START_TIME=$(date +%s)

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    ELAPSED_STR=$([ $ELAPSED -ge 60 ] && echo "$((ELAPSED / 60))m $((ELAPSED % 60))s" || echo "${ELAPSED}s")
    progress "$YELLOW" "Status: downloading model ... Elapsed: ${ELAPSED_STR}"

    if ssh "${SSH_OPTS[@]}" "root@${INSTANCE_IP}" "curl -s http://localhost:8000/v1/models" </dev/null 2>/dev/null | grep -q '"id":"Qwen/Qwen3-14B-FP8"'; then
        log_to_file "INFO" "vLLM model loaded successfully in ${ELAPSED_STR}"
        progress "$NC" "vLLM model is loaded (took ${ELAPSED_STR})"
        break
    fi
    if [ $ELAPSED -ge 600 ]; then
        log_to_file "WARN" "vLLM model load timeout after ${ELAPSED_STR}"
        warn "Timeout waiting for vLLM model to load. Model may still be downloading."
        break
    fi
    sleep 2
done
echo ""
echo ""

#==============================================================================
# Show Access URL
#==============================================================================
print_msg "$GREEN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_msg "$BOLD" " 🎉 Setup Completed !!"
print_msg "$GREEN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_msg "$BOLD$GREEN" "✅ Your AI LLM instance is now ready !!"
echo ""
print_msg "$CYAN" "📊 Instance Details:"
echo "   Instance ID:    $INSTANCE_ID"
echo "   Instance Label: $INSTANCE_LABEL"
echo "   IP Address:     $INSTANCE_IP"
echo "   Region:         $SELECTED_REGION"
echo "   Instance Type:  $SELECTED_TYPE"
echo ""
print_msg "$CYAN" "🔐 Access Credentials:"
echo "   SSH:         ssh -i ${SSH_KEY_FILE} root@${INSTANCE_IP}"
echo "   SSH Key:     ${SSH_KEY_FILE}"
echo "   Password:    ${INSTANCE_PASSWORD}"
echo ""
print_msg "$CYAN" "📋 Execution Log:"
echo "   Log file:       $LOG_FILE"
echo ""
print_msg "$GREEN" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
INSTANCE_IP_LABEL=$(echo "$INSTANCE_IP" | tr . -)
print_msg "$YELLOW" "💡 Next Steps:"
printf "   1. 🌐 Access Open-WebUI: ${CYAN}https://${INSTANCE_IP_LABEL}.ip.linodeusercontent.com${NC}\n"
echo "   2. Create admin user account (your account data is stored only on your instance)"
echo "   3. Start chatting with the model running on your GPU instance !!"
echo ""
print_msg "$YELLOW" "📁 Check AI Stack Configuration:"
printf "   Docker Compose: ${CYAN}/opt/${PROJECT_NAME}/docker-compose.yml${NC}\n"
echo "   Services: Caddy (port 80/443) + vLLM (port 8000) + Open-WebUI (port 8080)"
echo ""
echo ""
echo "🚀 Enjoy your AI Quickstart Qwen3-14B-FP8 on Akamai Cloud !!"
echo ""
echo ""
log_to_file "INFO" "Deployment completed successfully"
log_to_file "INFO" "Instance URL: https://${INSTANCE_IP_LABEL}.ip.linodeusercontent.com"
