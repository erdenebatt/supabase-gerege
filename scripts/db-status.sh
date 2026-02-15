#!/usr/bin/env bash
# db-status.sh — Health monitor for Supabase Gerege
# Run: bash scripts/db-status.sh
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC}  $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Supabase Gerege — Health Status             ║${NC}"
echo -e "${BOLD}║  $(date '+%Y-%m-%d %H:%M:%S %Z')                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ─── 1. Container Health ─────────────────────────────────────
echo -e "${BOLD}── Container Status ──────────────────────────────${NC}"

CONTAINERS=(
    "supabase-db:PostgreSQL 15"
    "supabase-kong:Kong Gateway"
    "supabase-auth:GoTrue Auth"
    "supabase-rest:PostgREST"
    "supabase-realtime:Realtime"
    "supabase-storage:Storage API"
    "supabase-studio:Studio"
    "supabase-meta:Postgres Meta"
    "supabase-supavisor:Supavisor"
    "supabase-analytics:Analytics"
    "supabase-vector:Vector Logs"
)

for entry in "${CONTAINERS[@]}"; do
    IFS=':' read -r container label <<< "$entry"
    STATUS=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
    HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no_healthcheck{{end}}' "$container" 2>/dev/null || echo "unknown")

    if [ "$STATUS" = "running" ]; then
        if [ "$HEALTH" = "healthy" ]; then
            ok "$label ($container): running, healthy"
        else
            warn "$label ($container): running, $HEALTH"
        fi
    elif [ "$STATUS" = "not_found" ]; then
        fail "$label ($container): not found"
    else
        fail "$label ($container): $STATUS"
    fi
done

echo ""

# ─── 2. PostgreSQL Connection Check ──────────────────────────
echo -e "${BOLD}── PostgreSQL ────────────────────────────────────${NC}"

if docker exec supabase-db pg_isready -U postgres -h localhost > /dev/null 2>&1; then
    ok "pg_isready: accepting connections"
else
    fail "pg_isready: not accepting connections"
    echo ""
    echo "PostgreSQL is down. Remaining checks skipped."
    exit 1
fi

# PostgreSQL version
PG_VERSION=$(docker exec supabase-db psql -U postgres -t -c "SELECT version();" 2>/dev/null | head -1 | xargs)
info "Version: $PG_VERSION"

# ─── 3. Active Connections ────────────────────────────────────
echo ""
echo -e "${BOLD}── Connections ───────────────────────────────────${NC}"

TOTAL_CONN=$(docker exec supabase-db psql -U postgres -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs)
MAX_CONN=$(docker exec supabase-db psql -U postgres -t -c "SHOW max_connections;" 2>/dev/null | xargs)
info "Active connections: $TOTAL_CONN / $MAX_CONN"

# Connections by database
docker exec supabase-db psql -U postgres -t -c "
    SELECT '    ' || datname || ': ' || count(*)
    FROM pg_stat_activity
    WHERE datname IS NOT NULL
    GROUP BY datname
    ORDER BY count(*) DESC;
" 2>/dev/null

# ─── 4. Schemas and Table Sizes ──────────────────────────────
echo ""
echo -e "${BOLD}── Schemas & Tables ──────────────────────────────${NC}"

# Check schemas
SCHEMAS=$(docker exec supabase-db psql -U postgres -t -c "
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name IN ('public', 'gesign', 'eid', 'auth', 'storage')
    ORDER BY schema_name;
" 2>/dev/null)

for schema in $SCHEMAS; do
    ok "Schema: $schema"
done

# Table sizes (top 15)
echo ""
info "Top tables by size:"
docker exec supabase-db psql -U postgres -t -c "
    SELECT '    ' || schemaname || '.' || tablename || ': ' ||
           pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename))
    FROM pg_tables
    WHERE schemaname IN ('public', 'gesign', 'eid', 'auth')
    ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
    LIMIT 15;
" 2>/dev/null

# Row counts for custom tables
echo ""
info "Row counts (custom tables):"
for table in "public.users" "public.user_mfa_settings" "public.user_totp" "public.mfa_recovery_codes" \
             "gesign.certificates" "gesign.signing_logs" \
             "eid.national_id_metadata" "eid.verification_logs"; do
    COUNT=$(docker exec supabase-db psql -U postgres -t -c "SELECT count(*) FROM $table;" 2>/dev/null | xargs)
    if [ -n "$COUNT" ]; then
        info "    $table: $COUNT rows"
    fi
done

# ─── 5. Database Size ────────────────────────────────────────
echo ""
echo -e "${BOLD}── Database Size ─────────────────────────────────${NC}"

docker exec supabase-db psql -U postgres -t -c "
    SELECT '    ' || datname || ': ' || pg_size_pretty(pg_database_size(datname))
    FROM pg_database
    WHERE datname NOT LIKE 'template%'
    ORDER BY pg_database_size(datname) DESC;
" 2>/dev/null

# ─── 6. Replication Status ───────────────────────────────────
echo ""
echo -e "${BOLD}── Replication ───────────────────────────────────${NC}"

REPL_COUNT=$(docker exec supabase-db psql -U postgres -t -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | xargs)
if [ "$REPL_COUNT" -gt 0 ] 2>/dev/null; then
    info "Active replicas: $REPL_COUNT"
    docker exec supabase-db psql -U postgres -t -c "
        SELECT '    ' || client_addr || ' | state: ' || state || ' | lag: ' || replay_lag
        FROM pg_stat_replication;
    " 2>/dev/null
else
    info "No active replication (standalone mode)"
fi

# ─── 7. Disk Usage ───────────────────────────────────────────
echo ""
echo -e "${BOLD}── Disk Usage ────────────────────────────────────${NC}"

# Docker volumes
DB_SIZE=$(docker system df -v 2>/dev/null | grep "supabase-gerege_db-data" | awk '{print $3}' || echo "unknown")
info "DB volume: $DB_SIZE"

# Host disk
DISK_USAGE=$(df -h / 2>/dev/null | tail -1 | awk '{print $3 " / " $2 " (" $5 " used)"}')
info "Host disk: $DISK_USAGE"

# ─── 8. Memory Usage ─────────────────────────────────────────
echo ""
echo -e "${BOLD}── Container Memory ──────────────────────────────${NC}"

docker stats --no-stream --format "    {{.Name}}: {{.MemUsage}} ({{.MemPerc}})" 2>/dev/null | sort

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
echo -e "  Status check completed at $(date '+%H:%M:%S')"
echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
