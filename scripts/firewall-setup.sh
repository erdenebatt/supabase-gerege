#!/usr/bin/env bash
# firewall-setup.sh — UFW firewall rules for Supabase Gerege
# Run as root: sudo bash scripts/firewall-setup.sh
set -euo pipefail

echo "╔══════════════════════════════════════════════╗"
echo "║  Supabase Gerege — Firewall Setup            ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo bash $0)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# Load allowed IPs from .env
ALLOWED_DB_IPS=""
if [ -f "$ENV_FILE" ]; then
    ALLOWED_DB_IPS=$(grep '^ALLOWED_DB_IPS=' "$ENV_FILE" | cut -d= -f2 || true)
fi

if [ -z "$ALLOWED_DB_IPS" ] || [ "$ALLOWED_DB_IPS" = "elite-gerege-ip,other-server-ip" ]; then
    echo "WARNING: ALLOWED_DB_IPS not configured in .env"
    echo "  Edit .env and set ALLOWED_DB_IPS to comma-separated IP addresses"
    echo "  Example: ALLOWED_DB_IPS=10.0.0.1,10.0.0.2"
    echo ""
    read -r -p "Continue with SSH/HTTP/HTTPS only (no PostgreSQL access)? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted. Set ALLOWED_DB_IPS in .env first."
        exit 0
    fi
    ALLOWED_DB_IPS=""
fi

# Install UFW if not present
if ! command -v ufw &> /dev/null; then
    echo ">>> Installing UFW..."
    apt-get install -y -qq ufw
fi

echo ">>> Configuring UFW rules..."

# Reset to clean state
ufw --force reset > /dev/null 2>&1

# Default policies
ufw default deny incoming
ufw default allow outgoing

# ─── Allow SSH (always) ──────────────────────────────────────
ufw allow 22/tcp comment "SSH"
echo "    Allow: SSH (22/tcp) from anywhere"

# ─── Allow HTTP/HTTPS (for Nginx proxy) ──────────────────────
ufw allow 80/tcp comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
echo "    Allow: HTTP (80/tcp) from anywhere"
echo "    Allow: HTTPS (443/tcp) from anywhere"

# ─── Allow Kong API Gateway ──────────────────────────────────
ufw allow 8000/tcp comment "Kong API Gateway"
echo "    Allow: Kong (8000/tcp) from anywhere"

# ─── Allow PostgreSQL ONLY from specified IPs ─────────────────
if [ -n "$ALLOWED_DB_IPS" ]; then
    IFS=',' read -ra IPS <<< "$ALLOWED_DB_IPS"
    for ip in "${IPS[@]}"; do
        ip=$(echo "$ip" | xargs)  # Trim whitespace
        if [ -n "$ip" ]; then
            ufw allow from "$ip" to any port 5432 proto tcp comment "PostgreSQL from $ip"
            echo "    Allow: PostgreSQL (5432/tcp) from $ip"
        fi
    done
else
    echo "    SKIP: PostgreSQL (5432) — no ALLOWED_DB_IPS configured"
fi

# ─── Allow Supavisor transaction port from specified IPs ──────
if [ -n "$ALLOWED_DB_IPS" ]; then
    IFS=',' read -ra IPS <<< "$ALLOWED_DB_IPS"
    for ip in "${IPS[@]}"; do
        ip=$(echo "$ip" | xargs)
        if [ -n "$ip" ]; then
            ufw allow from "$ip" to any port 6543 proto tcp comment "Supavisor from $ip"
            echo "    Allow: Supavisor (6543/tcp) from $ip"
        fi
    done
fi

# ─── Enable UFW ──────────────────────────────────────────────
echo ""
echo ">>> Enabling UFW..."
ufw --force enable

echo ""
echo ">>> Current rules:"
ufw status verbose

echo ""
echo "========================================"
echo "  Firewall configured!"
echo ""
echo "  Public access: SSH, HTTP, HTTPS, Kong"
echo "  Restricted:    PostgreSQL (5432),"
echo "                 Supavisor (6543)"
echo "========================================"
