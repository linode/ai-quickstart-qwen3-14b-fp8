set -e

# Project name (used for paths, service names, etc.)
PROJECT_NAME="ai-quickstart-qwen3-14b-fp8"

# Function to send ntfy notification
notify() {
    local message="$1"
    curl -s -d "$message" "https://ntfy.sh/$(hostname)" || true
}

notify "☁️ cloud-init package install finished. starting install.sh..."
sleep 2

# Install NVIDIA drivers
notify "🎮 Installing NVIDIA drivers...(this may takes 2 - 3 minutes)"
ubuntu-drivers autoinstall

# Install Docker
notify "🐳 Installing Docker & Compose..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

# Add NVIDIA Container Toolkit repository
notify "📦 Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Configure Docker registry mirrors
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://mirror.gcr.io"
  ]
}
EOF

# Update and install NVIDIA Container Toolkit
apt-get update
apt-get install -y nvidia-container-toolkit

# Configure Docker for NVIDIA
nvidia-ctk runtime configure --runtime=docker

# Restart Docker to apply NVIDIA runtime configuration
systemctl restart docker

# Create systemd service for AI Quickstart Stack
notify "⚙️ Registering systemd service for ${PROJECT_NAME}..."
cat > /etc/systemd/system/${PROJECT_NAME}.service << EOF
[Unit]
Description=Start ${PROJECT_NAME} Stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/${PROJECT_NAME}
ExecStart=/usr/bin/docker compose --progress quiet up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Update Caddyfile domain configuration
notify "🌐 Configuring Caddy domain with public IP..."
IP_LABEL=$(curl -s https://ipinfo.io/ip | tr . -)
sed -i "s/_PUBLIC_IP_LABEL_PLACEHOLDER_/${IP_LABEL}/g" /opt/${PROJECT_NAME}/Caddyfile

# Enable service (will start containers on boot)
systemctl daemon-reload
systemctl enable ${PROJECT_NAME}.service

# Create vLLM quantization config files for RTX 4000 Ada
notify "📝 Creating vLLM quantization configs for RTX 4000 Ada..."
mkdir -p /opt/${PROJECT_NAME}/configs

# All 4 config files share the same tuned parameters for RTX 4000 Ada
VLLM_CONFIG_CONTENT='{
    "1": {"BLOCK_SIZE_M": 16, "BLOCK_SIZE_N": 32, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "8": {"BLOCK_SIZE_M": 32, "BLOCK_SIZE_N": 32, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "32": {"BLOCK_SIZE_M": 32, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "128": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "512": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "1024": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "2048": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2}
}'

echo "$VLLM_CONFIG_CONTENT" > "/opt/${PROJECT_NAME}/configs/N=5120,K=5120,device_name=NVIDIA_RTX_4000_Ada_Generation,dtype=fp8_w8a8,block_shape=[128,128].json"
echo "$VLLM_CONFIG_CONTENT" > "/opt/${PROJECT_NAME}/configs/N=7168,K=5120,device_name=NVIDIA_RTX_4000_Ada_Generation,dtype=fp8_w8a8,block_shape=[128,128].json"
echo "$VLLM_CONFIG_CONTENT" > "/opt/${PROJECT_NAME}/configs/N=34816,K=5120,device_name=NVIDIA_RTX_4000_Ada_Generation,dtype=fp8_w8a8,block_shape=[128,128].json"
echo "$VLLM_CONFIG_CONTENT" > "/opt/${PROJECT_NAME}/configs/N=5120,K=17408,device_name=NVIDIA_RTX_4000_Ada_Generation,dtype=fp8_w8a8,block_shape=[128,128].json"

# Pull latest Docker images
notify "⬇️ Downloading latest vLLM & OpenWebUI container images... (this may take 2 - 3 min)..."
cd /opt/${PROJECT_NAME}
docker compose pull --quiet || true

# Check if NVIDIA modules exist for current kernel
CURRENT_KERNEL=$(uname -r)
if [ -f "/lib/modules/${CURRENT_KERNEL}/kernel/nvidia-580-open/nvidia.ko" ] || \
   [ -f "/lib/modules/${CURRENT_KERNEL}/updates/dkms/nvidia.ko" ]; then
    # Modules exist, load them and start containers now
    notify "🔧 Loading NVIDIA kernel modules..."
    modprobe nvidia 2>/dev/null || true
    modprobe nvidia-uvm 2>/dev/null || true
    modprobe nvidia-modeset 2>/dev/null || true

    # Verify driver is loaded
    if nvidia-smi > /dev/null 2>&1; then
        # Start AI Quickstart Stack
        cd /opt/${PROJECT_NAME}
        notify "🚀 Starting vLLM & OpenWebUI with docker compose up ..."
        docker compose up -d
        exit 0
    fi
fi

notify "🔄 Rebooting to load NVIDIA drivers... 🚀 vLLM & OpenWebUI setup will start after reboot"
reboot