-- 00-extensions.sql
-- Additional extensions and schemas for Gerege ecosystem
-- Run after supabase/postgres image has completed its own initialization
-- Execute via: docker exec supabase-db psql -U supabase_admin -d postgres -f /etc/supabase/init/00-extensions.sql

-- Additional extensions (supabase image already provides uuid-ossp, pgcrypto, pgjwt, etc.)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Create schemas required by Supabase services
CREATE SCHEMA IF NOT EXISTS _analytics;
CREATE SCHEMA IF NOT EXISTS _realtime;
GRANT ALL ON SCHEMA _analytics TO supabase_admin;
GRANT ALL ON SCHEMA _realtime TO supabase_admin;

-- Create custom schemas for Gerege ecosystem
CREATE SCHEMA IF NOT EXISTS gesign;
CREATE SCHEMA IF NOT EXISTS eid;

-- Grant usage on schemas to Supabase roles
GRANT USAGE ON SCHEMA gesign TO authenticated, service_role;
GRANT USAGE ON SCHEMA eid TO authenticated, service_role;
