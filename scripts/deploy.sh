#!/usr/bin/env bash
# deploy.sh — Deploy the Supabase Gerege stack
# Run from the project root: bash scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

echo "╔══════════════════════════════════════════════╗"
echo "║  Supabase Gerege — Deploy                    ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

cd "$PROJECT_DIR"

# ─── Pre-flight checks ───────────────────────────────────────
echo ">>> Pre-flight checks..."

# Check .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found!"
    echo "  Run: ./scripts/generate-secrets.sh"
    exit 1
fi

# Check docker is running
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker is not running!"
    exit 1
fi

# Check docker compose is available
if ! docker compose version > /dev/null 2>&1; then
    echo "ERROR: Docker Compose plugin not found!"
    exit 1
fi

# Validate required env vars
source "$ENV_FILE"
REQUIRED_VARS=("POSTGRES_PASSWORD" "JWT_SECRET" "ANON_KEY" "SERVICE_ROLE_KEY")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

echo "    .env file: OK"
echo "    Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
echo "    Compose: $(docker compose version --short)"
echo ""

# ─── Pull images ──────────────────────────────────────────────
echo ">>> Pulling Docker images (this may take a few minutes)..."
docker compose pull
echo ""

# ─── Start the stack ──────────────────────────────────────────
echo ">>> Starting Supabase stack..."
docker compose up -d
echo ""

# ─── Wait for health checks ──────────────────────────────────
echo ">>> Waiting for services to become healthy..."
TIMEOUT=120
ELAPSED=0
INTERVAL=5

wait_for_service() {
    local service="$1"
    local container="supabase-$service"
    local start=$SECONDS

    while [ $(( SECONDS - start )) -lt $TIMEOUT ]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")

        case "$health" in
            healthy)
                echo "    $container: HEALTHY ($(( SECONDS - start ))s)"
                return 0
                ;;
            unhealthy)
                echo "    $container: UNHEALTHY — checking logs..."
                docker logs --tail 20 "$container"
                return 1
                ;;
            *)
                sleep $INTERVAL
                ;;
        esac
    done

    echo "    $container: TIMEOUT after ${TIMEOUT}s"
    return 1
}

# Wait for critical services in order
SERVICES=("db" "analytics" "auth" "rest" "studio")
FAILED=0
for svc in "${SERVICES[@]}"; do
    if ! wait_for_service "$svc"; then
        FAILED=1
    fi
done

echo ""

# ─── Verify database ─────────────────────────────────────────
echo ">>> Verifying database..."
if docker exec supabase-db pg_isready -U postgres -h localhost > /dev/null 2>&1; then
    echo "    PostgreSQL: READY"

    # Check schemas exist
    SCHEMAS=$(docker exec supabase-db psql -U postgres -t -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name IN ('public','gesign','eid') ORDER BY schema_name;")
    echo "    Schemas: $(echo $SCHEMAS | tr -s ' ' ', ')"
else
    echo "    PostgreSQL: NOT READY"
    FAILED=1
fi

echo ""

# ─── Summary ──────────────────────────────────────────────────
if [ $FAILED -eq 0 ]; then
    echo "========================================"
    echo "  Deployment successful!"
    echo ""
    echo "  Studio:    http://localhost:${STUDIO_PORT:-3000}"
    echo "  Kong API:  http://localhost:${KONG_HTTP_PORT:-8000}"
    echo "  PostgreSQL: localhost:5432"
    echo ""
    echo "  Next: Run ./scripts/db-status.sh"
    echo "========================================"
else
    echo "========================================"
    echo "  Deployment completed with WARNINGS"
    echo "  Some services may still be starting."
    echo "  Run: docker compose ps"
    echo "  Run: ./scripts/db-status.sh"
    echo "========================================"
    exit 1
fi
