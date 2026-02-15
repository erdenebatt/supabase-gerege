#!/usr/bin/env bash
# setup-server.sh — System setup for Supabase Gerege dedicated database server
# Target: Ubuntu 22.04 / 16GB RAM / 6 vCPU / 130GB SSD
# Run as root: sudo bash scripts/setup-server.sh
set -euo pipefail

echo "╔══════════════════════════════════════════════╗"
echo "║  Supabase Gerege — Server Setup              ║"
echo "║  supabase.gerege.mn (38.180.242.174)         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo bash $0)"
    exit 1
fi

# ─── 1. Update system packages ───────────────────────────────
echo ">>> [1/6] Updating system packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# ─── 2. Install Docker CE + Docker Compose plugin ────────────
echo ">>> [2/6] Installing Docker..."
if ! command -v docker &> /dev/null; then
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources-list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    echo "    Docker installed: $(docker --version)"
else
    echo "    Docker already installed: $(docker --version)"
fi

echo "    Docker Compose: $(docker compose version)"

# ─── 3. Create 4GB swap file ─────────────────────────────────
echo ">>> [3/6] Configuring swap..."
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "    4GB swap created and enabled"
else
    echo "    Swap already exists: $(swapon --show | tail -1)"
fi

# ─── 4. Set timezone ─────────────────────────────────────────
echo ">>> [4/6] Setting timezone to Asia/Ulaanbaatar..."
timedatectl set-timezone Asia/Ulaanbaatar
echo "    Timezone: $(timedatectl show --property=Timezone --value)"

# ─── 5. Sysctl tuning for PostgreSQL ─────────────────────────
echo ">>> [5/6] Configuring sysctl for PostgreSQL..."
cat > /etc/sysctl.d/99-supabase.conf << 'SYSCTL'
# Supabase Gerege — PostgreSQL production tuning

# Shared memory — increase for large shared_buffers
kernel.shmmax = 4294967296
kernel.shmall = 1048576

# Virtual memory
vm.swappiness = 10
vm.overcommit_memory = 2
vm.overcommit_ratio = 80
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Network — for connection pooling
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.core.netdev_max_backlog = 65535

# File descriptors
fs.file-max = 2097152
SYSCTL

sysctl --system > /dev/null 2>&1
echo "    Sysctl applied"

# ─── 6. Install useful tools ─────────────────────────────────
echo ">>> [6/6] Installing utilities..."
apt-get install -y -qq htop iotop curl wget jq postgresql-client-14 ufw
echo "    Utilities installed"

echo ""
echo "========================================"
echo "  Server setup complete!"
echo "  Next steps:"
echo "    1. Run: ./scripts/firewall-setup.sh"
echo "    2. Run: ./scripts/generate-secrets.sh"
echo "    3. Run: ./scripts/deploy.sh"
echo "========================================"
