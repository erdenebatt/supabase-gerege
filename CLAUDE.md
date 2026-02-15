# Supabase Gerege — Architecture Documentation

## Overview

Dedicated Supabase database server for the **Gerege AI Ecosystem**. This is the "Spine" — the central database that all ecosystem services connect to.

- **Domain**: `supabase.gerege.mn`
- **Server**: 38.180.242.174 (6 vCPU, 16GB RAM, 130GB SSD, Ubuntu 22.04)
- **Stack**: Official Supabase Docker (PostgreSQL 15 + GoTrue + PostgREST + Realtime + Supavisor + Kong + Studio)

## Architecture

```
Internet
    │
    ├─ HTTPS ──→ Nginx (SSL termination at supabase.gerege.mn)
    │                │
    │                ├─ /auth/v1/*     ──→ Kong ──→ GoTrue (Auth)
    │                ├─ /rest/v1/*     ──→ Kong ──→ PostgREST (REST API)
    │                ├─ /realtime/v1/* ──→ Kong ──→ Realtime (WebSocket)
    │                ├─ /storage/v1/*  ──→ Kong ──→ Storage API
    │                └─ /*             ──→ Kong ──→ Studio (Dashboard)
    │
    ├─ TCP 5433 ──→ PostgreSQL 15 (direct, firewalled to ALLOWED_DB_IPS)
    ├─ TCP 5432 ──→ Supavisor (session mode, firewalled)
    └─ TCP 6543 ──→ Supavisor (transaction mode, firewalled)
```

## Database Schemas

| Schema   | Purpose                          | Tables                                         |
|----------|----------------------------------|-------------------------------------------------|
| `public` | Core user management + MFA + RBAC | users, organizations, user_mfa_settings, user_totp, mfa_recovery_codes |
| `gesign` | Digital signature service        | certificates, signing_logs                      |
| `eid`    | Electronic identity verification | national_id_metadata, verification_logs         |
| `auth`   | Supabase Auth (managed)          | users, sessions, mfa_factors, etc.              |
| `storage`| Supabase Storage (managed)       | buckets, objects, etc.                          |

## RBAC System

Multi-tenant organization-based role hierarchy using a PostgreSQL enum:

```
CITIZEN < OPERATOR < ORG_ADMIN < SUPER_ADMIN
```

### Role Permissions

| Resource | CITIZEN | OPERATOR | ORG_ADMIN | SUPER_ADMIN |
|----------|---------|----------|-----------|-------------|
| **users** (own) | SELECT, UPDATE | SELECT, UPDATE | SELECT, UPDATE | SELECT, UPDATE |
| **users** (same org) | -- | -- | SELECT, UPDATE | ALL |
| **users** (all) | -- | -- | -- | ALL |
| **organizations** | SELECT | SELECT | SELECT | ALL |
| **MFA tables** (own) | ALL | ALL | ALL | ALL |
| **MFA tables** (others) | -- | -- | -- | SELECT |
| **certificates/signing_logs** (own) | SELECT | SELECT | SELECT | SELECT |
| **certificates/signing_logs** (org) | -- | SELECT | SELECT | ALL |
| **national_id/verification_logs** (own) | SELECT | SELECT | SELECT | SELECT |
| **national_id/verification_logs** (org) | -- | SELECT, UPDATE/INSERT | SELECT, UPDATE/INSERT | ALL |

### Key Details

- **Enum type**: `public.user_role` — enforced at DB level, supports `>=` comparisons for hierarchy
- **Organizations table**: `public.organizations` with `domain` for auto-assignment on signup
- **`users.org_id`**: Nullable FK to `organizations` — unaffiliated users have `NULL`
- **`users.role`**: `user_role` enum (was VARCHAR), defaults to `CITIZEN`
- **`current_user_info()`**: `SECURITY DEFINER` helper that returns `(user_id, org_id, role)` — used by all RLS policies to avoid infinite recursion
- **Auth hook**: Trigger `on_auth_user_created` on `auth.users` auto-provisions `public.users` rows:
  - `@gerege.mn` emails → `SUPER_ADMIN` role + Gerege org
  - Other emails → `CITIZEN` role + org matched by domain (if exists)
- **Anon access**: Revoked on all user-data tables — authenticated-only

## Resource Allocation (16GB Server)

| Service     | RAM Limit | RAM Reserve | Notes                |
|-------------|-----------|-------------|----------------------|
| PostgreSQL  | 8GB       | 6GB         | shared_buffers=2GB   |
| Supavisor   | 2GB       | 1GB         | Connection pooling   |
| GoTrue      | 512MB     | 256MB       | Auth service         |
| PostgREST   | 512MB     | 256MB       | REST API             |
| Realtime    | 512MB     | 256MB       | WebSocket            |
| Kong        | 512MB     | 256MB       | API gateway          |
| Studio      | 512MB     | 256MB       | Dashboard            |
| Storage     | 512MB     | 256MB       | File storage API     |
| Meta        | 256MB     | 128MB       | DB introspection     |
| Analytics   | 512MB     | 256MB       | Logflare             |
| Vector      | 256MB     | 128MB       | Log collection       |
| Imgproxy    | 256MB     | 128MB       | Image transformation |
| **Total**   | **~14GB** | **~9.5GB**  | Fits 16GB with OS    |

## Deployment Workflow

```bash
# 1. Server preparation (run on server as root)
sudo bash scripts/setup-server.sh

# 2. Configure firewall
sudo bash scripts/firewall-setup.sh

# 3. Generate secrets (creates .env from .env.example)
bash scripts/generate-secrets.sh

# 4. Edit .env — set SMTP, ALLOWED_DB_IPS, etc.
nano .env

# 5. Deploy the stack
bash scripts/deploy.sh

# 6. Check health
bash scripts/db-status.sh
```

## Ports

| Port | Service | Access |
|------|---------|--------|
| 22 | SSH | Public |
| 80 | HTTP | Public (301 → HTTPS) |
| 443 | HTTPS (Nginx) | Public — SSL via Let's Encrypt |
| 3000 | Studio | Internal (proxied via Kong) |
| 5432 | Supavisor (session mode) | Firewalled to `ALLOWED_DB_IPS` |
| 5433 | PostgreSQL direct | Firewalled to `ALLOWED_DB_IPS` |
| 6543 | Supavisor (transaction mode) | Firewalled to `ALLOWED_DB_IPS` |
| 8000 | Kong API Gateway | Public (proxied via Nginx) |

## Firewall (UFW)

Managed by `scripts/firewall-setup.sh`. Default policy: deny incoming, allow outgoing.

**Public access:**
- SSH (22), HTTP (80), HTTPS (443), Kong (8000)

**Restricted to `ALLOWED_DB_IPS` only:**
- PostgreSQL direct (5433)
- Supavisor session (5432) and transaction (6543)

Currently allowed IPs (set in `.env`):
- `38.180.251.84` — elite-gerege server
- `150.228.176.233` — admin

To add a new IP:
```bash
# 1. Edit .env
nano .env  # add IP to ALLOWED_DB_IPS

# 2. Add UFW rules
ufw allow from NEW_IP to any port 5433 proto tcp comment 'PostgreSQL direct'
ufw allow from NEW_IP to any port 5432 proto tcp comment 'Supavisor session'
ufw allow from NEW_IP to any port 6543 proto tcp comment 'Supavisor transaction'
```

## Security

- All API traffic routed through Kong with JWT authentication
- Studio dashboard protected by basic auth (credentials in `.env`)
- PostgreSQL ports (5432/5433/6543) firewalled — only `ALLOWED_DB_IPS` can connect
- SSL terminated at Nginx with Let's Encrypt (auto-renew via certbot timer)
- TLS 1.2+ with HSTS enabled
- TOTP secrets encrypted with AES-256-GCM at application level
- Recovery codes stored as SHA-256 hashes
- Row Level Security (RLS) enabled on all custom tables with org-scoped RBAC policies
- Auth hook auto-provisions users with role/org assignment on signup

## Key Files

- `docker-compose.yml` — All service definitions with resource limits
- `.env` — Secrets and configuration (never commit)
- `volumes/db/postgresql.conf` — PostgreSQL tuning for 8GB allocation
- `volumes/db/init/00-extensions.sql` — Extensions and schema creation
- `volumes/db/init/01-public-schema.sql` — Users, MFA tables, base grants
- `volumes/db/init/02-gesign-schema.sql` — Digital signature tables
- `volumes/db/init/03-eid-schema.sql` — Electronic identity tables
- `volumes/db/init/04-rbac-organizations.sql` — RBAC enum, organizations, role migration, RLS policies, auth hook
- `volumes/api/kong.yml` — API gateway route definitions
- `scripts/` — Server setup, deployment, and monitoring scripts

## Connecting from Other Services

```bash
# Direct PostgreSQL connection (from allowed IPs only, port 5433)
psql "postgresql://supabase_admin:PASSWORD@38.180.242.174:5433/postgres"

# From elite-gerege (38.180.251.84):
PGPASSWORD=PASSWORD psql -h 38.180.242.174 -p 5433 -U supabase_admin -d postgres

# Via Supavisor transaction pooling (port 6543)
psql "postgresql://supabase_admin:PASSWORD@38.180.242.174:6543/postgres"

# REST API (requires authenticated JWT — anon access revoked on user-data tables)
curl https://supabase.gerege.mn/rest/v1/users \
  -H "apikey: ANON_KEY" \
  -H "Authorization: Bearer USER_JWT"

# REST API for gesign/eid schemas (use Accept-Profile header)
curl https://supabase.gerege.mn/rest/v1/certificates \
  -H "apikey: ANON_KEY" \
  -H "Authorization: Bearer USER_JWT" \
  -H "Accept-Profile: gesign"

# Auth API
curl https://supabase.gerege.mn/auth/v1/health \
  -H "apikey: ANON_KEY"
```

## Nginx / SSL

- Config: `/etc/nginx/sites-available/supabase.gerege.mn`
- Certificate: `/etc/letsencrypt/live/supabase.gerege.mn/`
- Auto-renewal: certbot systemd timer (runs twice daily)
- Proxies all HTTPS traffic to Kong on port 8000
- WebSocket upgrade headers configured for Realtime
