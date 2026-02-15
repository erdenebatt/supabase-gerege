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
    ├─ HTTPS ──→ Nginx (SSL termination)
    │                │
    │                ├─ /auth/v1/*     ──→ Kong ──→ GoTrue (Auth)
    │                ├─ /rest/v1/*     ──→ Kong ──→ PostgREST (REST API)
    │                ├─ /realtime/v1/* ──→ Kong ──→ Realtime (WebSocket)
    │                ├─ /storage/v1/*  ──→ Kong ──→ Storage API
    │                └─ /*             ──→ Kong ──→ Studio (Dashboard)
    │
    └─ TCP 5432 ──→ Supavisor (Connection Pooler) ──→ PostgreSQL 15
       (firewalled)
```

## Database Schemas

| Schema   | Purpose                          | Tables                                         |
|----------|----------------------------------|-------------------------------------------------|
| `public` | Core user management + MFA       | users, user_mfa_settings, user_totp, mfa_recovery_codes |
| `gesign` | Digital signature service        | certificates, signing_logs                      |
| `eid`    | Electronic identity verification | national_id_metadata, verification_logs         |
| `auth`   | Supabase Auth (managed)          | users, sessions, mfa_factors, etc.              |
| `storage`| Supabase Storage (managed)       | buckets, objects, etc.                          |

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

| Port | Service          | Access                  |
|------|------------------|-------------------------|
| 22   | SSH              | Public                  |
| 80   | HTTP             | Public (redirects HTTPS)|
| 443  | HTTPS (Nginx)    | Public                  |
| 3000 | Studio           | Internal (via Kong)     |
| 5432 | PostgreSQL       | Firewalled (ALLOWED_DB_IPS only) |
| 6543 | Supavisor (transaction mode) | Firewalled    |
| 8000 | Kong API Gateway | Public (via Nginx)      |

## Security

- All API traffic routed through Kong with JWT authentication
- PostgreSQL port (5432) firewalled — only allowed IPs can connect
- TOTP secrets encrypted with AES-256-GCM at application level
- Recovery codes stored as SHA-256 hashes
- Row Level Security (RLS) enabled on all custom tables
- SSL terminated at Nginx with TLS 1.2+ and HSTS

## Key Files

- `docker-compose.yml` — All service definitions with resource limits
- `.env` — Secrets and configuration (never commit)
- `volumes/db/postgresql.conf` — PostgreSQL tuning for 8GB allocation
- `volumes/db/init/*.sql` — Schema initialization (runs on first start)
- `volumes/api/kong.yml` — API gateway route definitions
- `scripts/` — Server setup, deployment, and monitoring scripts

## Connecting from Other Services

```bash
# Direct connection (from allowed IPs only)
psql "postgresql://postgres:PASSWORD@supabase.gerege.mn:5432/postgres"

# Via Supavisor (transaction pooling)
psql "postgresql://postgres:PASSWORD@supabase.gerege.mn:6543/postgres"

# REST API
curl https://supabase.gerege.mn/rest/v1/users \
  -H "apikey: ANON_KEY" \
  -H "Authorization: Bearer ANON_KEY"
```
