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
REQUIRED_VARS=("POSTGRES_PASSWORD" "JWT_SECRET" "ANON_KEY" "SERVICE_ROLE_KEY")
for var in "${REQUIRED_VARS[@]}"; do
    val=$(grep "^${var}=" "$ENV_FILE" | head -1 | cut -d= -f2-)
    if [ -z "$val" ]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

echo "    .env file: OK"
echo "    Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
echo "    Compose: $(docker compose version --short)"
echo ""

# ─── Generate kong.yml with actual API keys ──────────────────
echo ">>> Generating Kong config with API keys..."
ANON_KEY_VAL=$(grep "^ANON_KEY=" "$ENV_FILE" | cut -d= -f2-)
SERVICE_KEY_VAL=$(grep "^SERVICE_ROLE_KEY=" "$ENV_FILE" | cut -d= -f2-)
DASH_USER_VAL=$(grep "^DASHBOARD_USERNAME=" "$ENV_FILE" | cut -d= -f2-)
DASH_PASS_VAL=$(grep "^DASHBOARD_PASSWORD=" "$ENV_FILE" | cut -d= -f2-)
if [ -f "$PROJECT_DIR/volumes/api/kong.yml.template" ]; then
    KONG_TEMPLATE="$PROJECT_DIR/volumes/api/kong.yml.template"
else
    KONG_TEMPLATE="$PROJECT_DIR/volumes/api/kong.yml"
fi
sed \
    -e "s|\${SUPABASE_ANON_KEY}|${ANON_KEY_VAL}|g" \
    -e "s|\${SUPABASE_SERVICE_KEY}|${SERVICE_KEY_VAL}|g" \
    -e "s|\${DASHBOARD_USERNAME}|${DASH_USER_VAL}|g" \
    -e "s|\${DASHBOARD_PASSWORD}|${DASH_PASS_VAL}|g" \
    "$KONG_TEMPLATE" > "$PROJECT_DIR/volumes/api/kong.yml"
echo "    Kong config: OK"
echo ""

# ─── Pull images ──────────────────────────────────────────────
echo ">>> Pulling Docker images (this may take a few minutes)..."
docker compose pull
echo ""

# ─── Start database first ─────────────────────────────────────
echo ">>> Starting PostgreSQL..."
docker compose up -d db
echo "    Waiting for PostgreSQL to be healthy..."
TIMEOUT=60
START=$SECONDS
while [ $(( SECONDS - START )) -lt $TIMEOUT ]; do
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' supabase-db 2>/dev/null || echo "starting")
    if [ "$HEALTH" = "healthy" ]; then
        echo "    PostgreSQL: HEALTHY"
        break
    fi
    sleep 2
done

# Apply Gerege schemas before other services start
echo ">>> Applying Gerege database schemas..."
INIT_DIR="/etc/supabase/init"
for sql_file in 00-extensions.sql 01-public-schema.sql 02-gesign-schema.sql 03-eid-schema.sql 04-rbac-organizations.sql; do
    echo -n "    $sql_file: "
    if docker exec supabase-db psql -U supabase_admin -d postgres -f "$INIT_DIR/$sql_file" > /dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        docker exec supabase-db psql -U supabase_admin -d postgres -f "$INIT_DIR/$sql_file" 2>&1 | tail -5
    fi
done

# Set passwords for service roles
echo ">>> Setting service role passwords..."
PW=$(grep "^POSTGRES_PASSWORD=" "$ENV_FILE" | cut -d= -f2-)
for role in supabase_auth_admin supabase_storage_admin authenticator postgres supabase_admin; do
    docker exec supabase-db psql -U supabase_admin -d postgres -c "ALTER USER $role WITH PASSWORD '$PW';" > /dev/null 2>&1
done
echo "    Passwords set"

echo ""

# ─── Start the full stack ─────────────────────────────────────
echo ">>> Starting all services..."
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
echo ""
echo ">>> Verifying database..."
if docker exec supabase-db pg_isready -U supabase_admin -h localhost > /dev/null 2>&1; then
    echo "    PostgreSQL: READY"

    # Check schemas exist
    SCHEMAS=$(docker exec supabase-db psql -U supabase_admin -d postgres -t -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name IN ('public','gesign','eid') ORDER BY schema_name;")
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
    echo "  Studio:    http://localhost:3000"
    echo "  Kong API:  http://localhost:8000"
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
