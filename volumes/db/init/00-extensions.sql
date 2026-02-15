-- 00-extensions.sql
-- Required PostgreSQL extensions for Supabase + Gerege ecosystem
-- Runs automatically on first database initialization

-- Core Supabase extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgjwt SCHEMA extensions;

-- PostgREST
CREATE EXTENSION IF NOT EXISTS pg_graphql SCHEMA graphql;

-- Supabase Vault (encrypted secrets storage)
CREATE EXTENSION IF NOT EXISTS supabase_vault SCHEMA vault;

-- Full-text search (Mongolian + multilingual)
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS unaccent SCHEMA extensions;

-- Network types (for IP tracking in audit logs)
CREATE EXTENSION IF NOT EXISTS citext SCHEMA extensions;

-- Stats and monitoring
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- HTTP requests from SQL (useful for webhooks)
CREATE EXTENSION IF NOT EXISTS http SCHEMA extensions;

-- Create custom schemas for Gerege ecosystem
CREATE SCHEMA IF NOT EXISTS gesign;
CREATE SCHEMA IF NOT EXISTS eid;

-- Grant usage on schemas to Supabase roles
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA gesign TO authenticated, service_role;
GRANT USAGE ON SCHEMA eid TO authenticated, service_role;

-- Add schemas to PostgREST search path
ALTER DATABASE postgres SET search_path TO public, extensions, gesign, eid;
