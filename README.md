# Supabase Gerege

Dedicated Supabase database server for the **Gerege AI Ecosystem** — the "Spine" that all ecosystem services connect to.

| | |
|---|---|
| **Domain** | `supabase.gerege.mn` |
| **Server** | 6 vCPU, 16GB RAM, 130GB SSD, Ubuntu 22.04 |
| **Stack** | PostgreSQL 15, GoTrue, PostgREST, Realtime, Supavisor, Kong, Studio |

## Architecture

```
Internet
    |
    +-- HTTPS --> Nginx (SSL) --> Kong API Gateway
    |                               |-- /auth/v1/*     --> GoTrue (Auth)
    |                               |-- /rest/v1/*     --> PostgREST (REST API)
    |                               |-- /realtime/v1/* --> Realtime (WebSocket)
    |                               |-- /storage/v1/*  --> Storage API
    |                               +-- /*             --> Studio (Dashboard)
    |
    +-- TCP 5432 --> Supavisor (Pooler) --> PostgreSQL 15
        (firewalled)
```

## Database Schemas

| Schema | Purpose | Tables |
|--------|---------|--------|
| `public` | Core users + MFA | `users`, `user_mfa_settings`, `user_totp`, `mfa_recovery_codes` |
| `gesign` | Digital signatures | `certificates`, `signing_logs` |
| `eid` | Identity verification | `national_id_metadata`, `verification_logs` |
| `auth` | Supabase Auth (managed) | `users`, `sessions`, `mfa_factors`, ... |
| `storage` | Supabase Storage (managed) | `buckets`, `objects`, ... |

## Quick Start

### Prerequisites

- Ubuntu 22.04 server with 16GB RAM
- Domain pointing to the server IP
- SSH access as root

### Deploy

```bash
# 1. Server setup (Docker, swap, sysctl tuning)
sudo bash scripts/setup-server.sh

# 2. Firewall (SSH/HTTPS public, PostgreSQL restricted)
sudo bash scripts/firewall-setup.sh

# 3. Generate secrets (.env.example -> .env)
bash scripts/generate-secrets.sh

# 4. Configure SMTP and allowed IPs
nano .env

# 5. Deploy the stack
bash scripts/deploy.sh

# 6. Verify health
bash scripts/db-status.sh
```

## Project Structure

```
supabase-gerege/
├── .env.example                     # Environment template
├── docker-compose.yml               # Full Supabase stack (13 services)
├── volumes/
│   ├── db/
│   │   ├── postgresql.conf          # Tuned for 8GB (16GB server)
│   │   └── init/
│   │       ├── 00-extensions.sql    # Required extensions
│   │       ├── 01-public-schema.sql # Users + MFA tables
│   │       ├── 02-gesign-schema.sql # Digital signature tables
│   │       └── 03-eid-schema.sql    # eID verification tables
│   ├── api/
│   │   └── kong.yml                 # API gateway routes
│   └── logs/
│       └── vector.yml               # Log collection
├── nginx/
│   └── supabase.conf                # Nginx SSL reference config
├── scripts/
│   ├── setup-server.sh              # System setup
│   ├── generate-secrets.sh          # Secret generation
│   ├── deploy.sh                    # Stack deployment
│   ├── db-status.sh                 # Health monitoring
│   └── firewall-setup.sh            # UFW firewall rules
└── CLAUDE.md                        # Detailed architecture docs
```

## Resource Allocation

| Service | RAM Limit | RAM Reserve |
|---------|-----------|-------------|
| PostgreSQL 15 | 8GB | 6GB |
| Supavisor | 2GB | 1GB |
| GoTrue / PostgREST / Realtime / Kong / Studio / Storage | 512MB each | 256MB each |
| Meta / Vector / Imgproxy | 256MB each | 128MB each |
| **Total** | **~14GB** | **~9.5GB** |

## Connecting

```bash
# Direct PostgreSQL (from allowed IPs only)
psql "postgresql://postgres:PASSWORD@supabase.gerege.mn:5432/postgres"

# Connection pooler (transaction mode)
psql "postgresql://postgres:PASSWORD@supabase.gerege.mn:6543/postgres"

# REST API
curl https://supabase.gerege.mn/rest/v1/users \
  -H "apikey: YOUR_ANON_KEY" \
  -H "Authorization: Bearer YOUR_ANON_KEY"
```

## Security

- JWT authentication on all API routes via Kong
- PostgreSQL port firewalled to `ALLOWED_DB_IPS` only
- Row Level Security (RLS) on all custom tables
- TOTP secrets encrypted with AES-256-GCM
- Recovery codes stored as SHA-256 hashes
- TLS 1.2+ with HSTS at Nginx

## Ports

| Port | Service | Access |
|------|---------|--------|
| 22 | SSH | Public |
| 80/443 | HTTP/HTTPS (Nginx) | Public |
| 8000 | Kong API Gateway | Public (via Nginx) |
| 5432 | PostgreSQL | Firewalled |
| 6543 | Supavisor | Firewalled |
