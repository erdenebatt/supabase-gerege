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
    +-- HTTPS (443) --> Nginx (Let's Encrypt SSL) --> Kong API Gateway
    |                                                   |-- /auth/v1/*     --> GoTrue (Auth)
    |                                                   |-- /rest/v1/*     --> PostgREST (REST API)
    |                                                   |-- /realtime/v1/* --> Realtime (WebSocket)
    |                                                   |-- /storage/v1/*  --> Storage API
    |                                                   +-- /*             --> Studio (Dashboard)
    |
    +-- TCP 5433 --> PostgreSQL 15 (direct connection)
    +-- TCP 5432 --> Supavisor (session mode) --> PostgreSQL 15
    +-- TCP 6543 --> Supavisor (transaction mode) --> PostgreSQL 15
        (all firewalled to ALLOWED_DB_IPS only)
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
# Direct PostgreSQL (from allowed IPs only, port 5433)
psql "postgresql://supabase_admin:PASSWORD@38.180.242.174:5433/postgres"

# Via Supavisor transaction pooling (port 6543)
psql "postgresql://supabase_admin:PASSWORD@38.180.242.174:6543/postgres"

# REST API (from anywhere, requires API key)
curl https://supabase.gerege.mn/rest/v1/users \
  -H "apikey: YOUR_ANON_KEY" \
  -H "Authorization: Bearer YOUR_ANON_KEY"

# Auth health check
curl https://supabase.gerege.mn/auth/v1/health \
  -H "apikey: YOUR_ANON_KEY"
```

## Ports & Firewall

UFW firewall configured by `scripts/firewall-setup.sh`. Default: deny all incoming.

| Port | Service | Access |
|------|---------|--------|
| 22 | SSH | Public |
| 80 | HTTP | Public (301 → HTTPS) |
| 443 | HTTPS (Nginx) | Public — Let's Encrypt SSL |
| 8000 | Kong API Gateway | Public (proxied via Nginx) |
| 5433 | PostgreSQL direct | `ALLOWED_DB_IPS` only |
| 5432 | Supavisor (session) | `ALLOWED_DB_IPS` only |
| 6543 | Supavisor (transaction) | `ALLOWED_DB_IPS` only |

To grant a new server access to PostgreSQL:
```bash
# Add to .env ALLOWED_DB_IPS, then:
ufw allow from NEW_IP to any port 5433 proto tcp
ufw allow from NEW_IP to any port 5432 proto tcp
ufw allow from NEW_IP to any port 6543 proto tcp
```

## Security

- JWT authentication on all API routes via Kong
- Studio dashboard protected by basic auth (credentials in `.env`)
- Database ports firewalled — only `ALLOWED_DB_IPS` can connect
- SSL via Let's Encrypt with auto-renewal (certbot timer)
- TLS 1.2+ with HSTS at Nginx
- Row Level Security (RLS) on all custom tables
- TOTP secrets encrypted with AES-256-GCM
- Recovery codes stored as SHA-256 hashes
