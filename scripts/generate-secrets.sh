#!/usr/bin/env bash
# generate-secrets.sh — Generate all secrets for Supabase Gerege
# Creates .env file from .env.example with generated secrets
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE="$PROJECT_DIR/.env.example"

echo "╔══════════════════════════════════════════════╗"
echo "║  Supabase Gerege — Secret Generation         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Check dependencies
for cmd in openssl python3; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: $cmd is required but not installed."
        exit 1
    fi
done

# Don't overwrite existing .env
if [ -f "$ENV_FILE" ]; then
    echo "WARNING: .env already exists at $ENV_FILE"
    read -r -p "Overwrite? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Check .env.example exists
if [ ! -f "$ENV_EXAMPLE" ]; then
    echo "ERROR: .env.example not found at $ENV_EXAMPLE"
    exit 1
fi

echo ">>> Generating secrets..."

# Generate random passwords
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)
JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
DASHBOARD_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
LOGFLARE_API_KEY=$(openssl rand -hex 16)

echo "    POSTGRES_PASSWORD: generated (${#POSTGRES_PASSWORD} chars)"
echo "    JWT_SECRET: generated (${#JWT_SECRET} chars)"
echo "    DASHBOARD_PASSWORD: generated (${#DASHBOARD_PASSWORD} chars)"
echo "    LOGFLARE_API_KEY: generated (${#LOGFLARE_API_KEY} chars)"

# Generate Supabase JWT tokens (ANON_KEY and SERVICE_ROLE_KEY)
# These are JWTs signed with the JWT_SECRET
echo ">>> Generating JWT API keys..."

generate_jwt() {
    local role="$1"
    local secret="$2"
    local iss="supabase"
    # Expire in 10 years
    local exp=$(( $(date +%s) + 315360000 ))
    local iat=$(date +%s)

    python3 -c "
import hmac, hashlib, base64, json

def base64url_encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header = {'alg': 'HS256', 'typ': 'JWT'}
payload = {
    'role': '$role',
    'iss': '$iss',
    'iat': $iat,
    'exp': $exp
}

header_b64 = base64url_encode(json.dumps(header, separators=(',', ':')).encode())
payload_b64 = base64url_encode(json.dumps(payload, separators=(',', ':')).encode())
signing_input = f'{header_b64}.{payload_b64}'
signature = hmac.new('$secret'.encode(), signing_input.encode(), hashlib.sha256).digest()
signature_b64 = base64url_encode(signature)
print(f'{signing_input}.{signature_b64}')
"
}

ANON_KEY=$(generate_jwt "anon" "$JWT_SECRET")
SERVICE_ROLE_KEY=$(generate_jwt "service_role" "$JWT_SECRET")

echo "    ANON_KEY: ${ANON_KEY:0:30}..."
echo "    SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY:0:30}..."

# Copy template and replace secrets
echo ">>> Writing .env file..."
cp "$ENV_EXAMPLE" "$ENV_FILE"

# Replace placeholder values in .env
sed -i.bak \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" \
    -e "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" \
    -e "s|^ANON_KEY=.*|ANON_KEY=$ANON_KEY|" \
    -e "s|^SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY|" \
    -e "s|^DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD|" \
    -e "s|^LOGFLARE_API_KEY=.*|LOGFLARE_API_KEY=$LOGFLARE_API_KEY|" \
    -e "s|^LOGFLARE_LOGGER_BACKEND_API_KEY=.*|LOGFLARE_LOGGER_BACKEND_API_KEY=$LOGFLARE_API_KEY|" \
    "$ENV_FILE"

rm -f "$ENV_FILE.bak"

# Set restrictive permissions
chmod 600 "$ENV_FILE"

echo ""
echo "========================================"
echo "  Secrets generated successfully!"
echo "  File: $ENV_FILE (mode 600)"
echo ""
echo "  IMPORTANT: Update these manually:"
echo "    - GOTRUE_SMTP_* (email settings)"
echo "    - ALLOWED_DB_IPS (firewall IPs)"
echo "========================================"
