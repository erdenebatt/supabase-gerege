-- 04-rbac-organizations.sql
-- Multi-Tenant Organization-Based RBAC System
-- Part of the Gerege AI Ecosystem "Spine" database
--
-- Adds: user_role enum, organizations table, org_id FK on users,
--       RBAC-aware RLS policies, current_user_info() helper,
--       and auth hook for auto-provisioning on signup.
--
-- Safe to re-run (uses IF NOT EXISTS / DO blocks where possible).

BEGIN;

-- ═══════════════════════════════════════════════════════════════
-- A. Enum Type
-- ═══════════════════════════════════════════════════════════════
DO $$ BEGIN
    CREATE TYPE public.user_role AS ENUM ('CITIZEN', 'OPERATOR', 'ORG_ADMIN', 'SUPER_ADMIN');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;


-- ═══════════════════════════════════════════════════════════════
-- B. Organizations Table
-- ═══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.organizations (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    registration_number VARCHAR(50) UNIQUE,
    domain VARCHAR(255) UNIQUE,
    status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'suspended', 'inactive')),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_organizations_domain ON public.organizations (domain);
CREATE INDEX IF NOT EXISTS idx_organizations_status ON public.organizations (status);

-- Reuse the existing handle_updated_at() trigger function from 01-public-schema.sql
DO $$ BEGIN
    CREATE TRIGGER set_organizations_updated_at
        BEFORE UPDATE ON public.organizations
        FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;


-- ═══════════════════════════════════════════════════════════════
-- C. Seed Gerege Organization
-- ═══════════════════════════════════════════════════════════════
INSERT INTO public.organizations (name, domain, status)
VALUES ('Gerege Systems', 'gerege.mn', 'active')
ON CONFLICT (domain) DO UPDATE SET name = 'Gerege Systems';


-- ═══════════════════════════════════════════════════════════════
-- D. Alter public.users — add org_id, migrate role to enum
-- ═══════════════════════════════════════════════════════════════

-- D1. Add org_id column (idempotent)
DO $$ BEGIN
    ALTER TABLE public.users ADD COLUMN org_id UUID REFERENCES public.organizations(id) ON DELETE SET NULL;
EXCEPTION
    WHEN duplicate_column THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_users_org_id ON public.users (org_id);

-- D2. Migrate role column from VARCHAR to user_role enum
-- Strategy: add new enum column, copy data, drop old, rename new.
DO $$
DECLARE
    col_type text;
BEGIN
    -- Check the current type of the role column
    SELECT data_type INTO col_type
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'role';

    -- Only migrate if still VARCHAR (not yet migrated)
    IF col_type = 'character varying' THEN
        -- Add temporary enum column
        ALTER TABLE public.users ADD COLUMN role_new public.user_role NOT NULL DEFAULT 'CITIZEN';

        -- Map existing text values to enum
        UPDATE public.users SET role_new = CASE
            WHEN role = 'SUPER_ADMIN'  THEN 'SUPER_ADMIN'::public.user_role
            WHEN role = 'super_admin'  THEN 'SUPER_ADMIN'::public.user_role
            WHEN role = 'admin'        THEN 'ORG_ADMIN'::public.user_role
            WHEN role = 'ORG_ADMIN'    THEN 'ORG_ADMIN'::public.user_role
            WHEN role = 'OPERATOR'     THEN 'OPERATOR'::public.user_role
            WHEN role = 'operator'     THEN 'OPERATOR'::public.user_role
            ELSE 'CITIZEN'::public.user_role
        END;

        -- Swap columns
        ALTER TABLE public.users DROP COLUMN role;
        ALTER TABLE public.users RENAME COLUMN role_new TO role;
    END IF;
END $$;

-- D3. Drop the old freetext organization column (no longer needed)
DO $$ BEGIN
    ALTER TABLE public.users DROP COLUMN IF EXISTS organization;
END $$;


-- ═══════════════════════════════════════════════════════════════
-- E. Helper Function: current_user_info()
-- ═══════════════════════════════════════════════════════════════
-- Returns the current authenticated user's id, org_id, and role.
-- SECURITY DEFINER so it bypasses RLS (avoids infinite recursion
-- when RLS policies on public.users call this function).
-- STABLE for per-statement caching.
CREATE OR REPLACE FUNCTION public.current_user_info()
RETURNS TABLE(user_id UUID, org_id UUID, role public.user_role)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id, u.org_id, u.role
    FROM public.users u
    WHERE u.auth_user_id = auth.uid()
    LIMIT 1;
$$;


-- ═══════════════════════════════════════════════════════════════
-- F. Drop ALL Existing RLS Policies
-- ═══════════════════════════════════════════════════════════════
-- Drop legacy policies (from 01-public-schema.sql)
DROP POLICY IF EXISTS "Users can view own profile" ON public.users;
DROP POLICY IF EXISTS "Users can update own profile" ON public.users;
DROP POLICY IF EXISTS "Service role has full access to users" ON public.users;
DROP POLICY IF EXISTS "Users can manage own MFA settings" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "Service role has full access to MFA settings" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "Users can manage own TOTP" ON public.user_totp;
DROP POLICY IF EXISTS "Service role has full access to TOTP" ON public.user_totp;
DROP POLICY IF EXISTS "Users can manage own recovery codes" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "Service role has full access to recovery codes" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "Users can view own certificates" ON gesign.certificates;
DROP POLICY IF EXISTS "Service role has full access to certificates" ON gesign.certificates;
DROP POLICY IF EXISTS "Users can view own signing logs" ON gesign.signing_logs;
DROP POLICY IF EXISTS "Service role has full access to signing logs" ON gesign.signing_logs;
DROP POLICY IF EXISTS "Users can view own national ID" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "Service role has full access to national ID" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "Users can view own verification logs" ON eid.verification_logs;
DROP POLICY IF EXISTS "Service role has full access to verification logs" ON eid.verification_logs;

-- Drop previous RBAC policies (from prior version of this file)
-- public.users
DROP POLICY IF EXISTS "users_select_own" ON public.users;
DROP POLICY IF EXISTS "users_select_org" ON public.users;
DROP POLICY IF EXISTS "users_select_all" ON public.users;
DROP POLICY IF EXISTS "users_select" ON public.users;
DROP POLICY IF EXISTS "users_update_own" ON public.users;
DROP POLICY IF EXISTS "users_update_org" ON public.users;
DROP POLICY IF EXISTS "users_update_all" ON public.users;
DROP POLICY IF EXISTS "users_update" ON public.users;
DROP POLICY IF EXISTS "users_insert_admin" ON public.users;
DROP POLICY IF EXISTS "users_delete_admin" ON public.users;
DROP POLICY IF EXISTS "users_service_role" ON public.users;
-- public.user_mfa_settings
DROP POLICY IF EXISTS "mfa_settings_own" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "mfa_settings_select_admin" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "mfa_settings_select" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "mfa_settings_insert" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "mfa_settings_update" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "mfa_settings_delete" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "mfa_settings_service_role" ON public.user_mfa_settings;
-- public.user_totp
DROP POLICY IF EXISTS "totp_own" ON public.user_totp;
DROP POLICY IF EXISTS "totp_select_admin" ON public.user_totp;
DROP POLICY IF EXISTS "totp_select" ON public.user_totp;
DROP POLICY IF EXISTS "totp_insert" ON public.user_totp;
DROP POLICY IF EXISTS "totp_update" ON public.user_totp;
DROP POLICY IF EXISTS "totp_delete" ON public.user_totp;
DROP POLICY IF EXISTS "totp_service_role" ON public.user_totp;
-- public.mfa_recovery_codes
DROP POLICY IF EXISTS "recovery_codes_own" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "recovery_codes_select_admin" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "recovery_codes_select" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "recovery_codes_insert" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "recovery_codes_update" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "recovery_codes_delete" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "recovery_codes_service_role" ON public.mfa_recovery_codes;
-- gesign.certificates
DROP POLICY IF EXISTS "certificates_select_own" ON gesign.certificates;
DROP POLICY IF EXISTS "certificates_select_org" ON gesign.certificates;
DROP POLICY IF EXISTS "certificates_all_admin" ON gesign.certificates;
DROP POLICY IF EXISTS "certificates_select" ON gesign.certificates;
DROP POLICY IF EXISTS "certificates_insert_admin" ON gesign.certificates;
DROP POLICY IF EXISTS "certificates_update_admin" ON gesign.certificates;
DROP POLICY IF EXISTS "certificates_delete_admin" ON gesign.certificates;
DROP POLICY IF EXISTS "certificates_service_role" ON gesign.certificates;
-- gesign.signing_logs
DROP POLICY IF EXISTS "signing_logs_select_own" ON gesign.signing_logs;
DROP POLICY IF EXISTS "signing_logs_select_org" ON gesign.signing_logs;
DROP POLICY IF EXISTS "signing_logs_all_admin" ON gesign.signing_logs;
DROP POLICY IF EXISTS "signing_logs_select" ON gesign.signing_logs;
DROP POLICY IF EXISTS "signing_logs_insert_admin" ON gesign.signing_logs;
DROP POLICY IF EXISTS "signing_logs_update_admin" ON gesign.signing_logs;
DROP POLICY IF EXISTS "signing_logs_delete_admin" ON gesign.signing_logs;
DROP POLICY IF EXISTS "signing_logs_service_role" ON gesign.signing_logs;
-- eid.national_id_metadata
DROP POLICY IF EXISTS "national_id_select_own" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_select_org" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_update_org" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_all_admin" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_select" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_update" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_insert_admin" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_delete_admin" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "national_id_service_role" ON eid.national_id_metadata;
-- eid.verification_logs
DROP POLICY IF EXISTS "verification_logs_select_own" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_select_org" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_insert_org" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_all_admin" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_select" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_insert" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_update_admin" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_delete_admin" ON eid.verification_logs;
DROP POLICY IF EXISTS "verification_logs_service_role" ON eid.verification_logs;
-- public.organizations
DROP POLICY IF EXISTS "organizations_select_authenticated" ON public.organizations;
DROP POLICY IF EXISTS "organizations_all_admin" ON public.organizations;
DROP POLICY IF EXISTS "organizations_select" ON public.organizations;
DROP POLICY IF EXISTS "organizations_insert_admin" ON public.organizations;
DROP POLICY IF EXISTS "organizations_update_admin" ON public.organizations;
DROP POLICY IF EXISTS "organizations_delete_admin" ON public.organizations;
DROP POLICY IF EXISTS "organizations_service_role" ON public.organizations;


-- ═══════════════════════════════════════════════════════════════
-- G. RLS Policies — public.users (5 policies)
-- ═══════════════════════════════════════════════════════════════
-- One policy per (role, action) — no multiple_permissive_policies warnings.

-- G1. SELECT: own row OR ORG_ADMIN+ same org OR SUPER_ADMIN
CREATE POLICY "users_select" ON public.users
    FOR SELECT TO authenticated
    USING (
        auth_user_id = (SELECT auth.uid())
        OR (
            org_id IS NOT NULL
            AND org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
            AND (SELECT cui.role FROM public.current_user_info() cui) >= 'ORG_ADMIN'::public.user_role
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G2. UPDATE: own row OR ORG_ADMIN+ same org OR SUPER_ADMIN
CREATE POLICY "users_update" ON public.users
    FOR UPDATE TO authenticated
    USING (
        auth_user_id = (SELECT auth.uid())
        OR (
            org_id IS NOT NULL
            AND org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
            AND (SELECT cui.role FROM public.current_user_info() cui) >= 'ORG_ADMIN'::public.user_role
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        auth_user_id = (SELECT auth.uid())
        OR (
            org_id IS NOT NULL
            AND org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
            AND (SELECT cui.role FROM public.current_user_info() cui) >= 'ORG_ADMIN'::public.user_role
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G3. INSERT: SUPER_ADMIN only
CREATE POLICY "users_insert_admin" ON public.users
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G4. DELETE: SUPER_ADMIN only
CREATE POLICY "users_delete_admin" ON public.users
    FOR DELETE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G5. Service role bypass
CREATE POLICY "users_service_role" ON public.users
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- H. RLS Policies — MFA Tables (5 policies each, 15 total)
-- ═══════════════════════════════════════════════════════════════
-- Breaks up the old FOR ALL into per-action policies.
-- SELECT allows own OR SUPER_ADMIN; INSERT/UPDATE/DELETE are own-only.

-- ── user_mfa_settings ──

CREATE POLICY "mfa_settings_select" ON public.user_mfa_settings
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT cui.user_id FROM public.current_user_info() cui)
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "mfa_settings_insert" ON public.user_mfa_settings
    FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "mfa_settings_update" ON public.user_mfa_settings
    FOR UPDATE TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui))
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "mfa_settings_delete" ON public.user_mfa_settings
    FOR DELETE TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "mfa_settings_service_role" ON public.user_mfa_settings
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ── user_totp ──

CREATE POLICY "totp_select" ON public.user_totp
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT cui.user_id FROM public.current_user_info() cui)
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "totp_insert" ON public.user_totp
    FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "totp_update" ON public.user_totp
    FOR UPDATE TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui))
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "totp_delete" ON public.user_totp
    FOR DELETE TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "totp_service_role" ON public.user_totp
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ── mfa_recovery_codes ──

CREATE POLICY "recovery_codes_select" ON public.mfa_recovery_codes
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT cui.user_id FROM public.current_user_info() cui)
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "recovery_codes_insert" ON public.mfa_recovery_codes
    FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "recovery_codes_update" ON public.mfa_recovery_codes
    FOR UPDATE TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui))
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "recovery_codes_delete" ON public.mfa_recovery_codes
    FOR DELETE TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "recovery_codes_service_role" ON public.mfa_recovery_codes
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- I. RLS Policies — gesign schema (5 policies each, 10 total)
-- ═══════════════════════════════════════════════════════════════
-- SELECT consolidated: own OR org(OPERATOR+) OR SUPER_ADMIN
-- INSERT/UPDATE/DELETE: SUPER_ADMIN only (no more FOR ALL overlap)

-- ── certificates ──

CREATE POLICY "certificates_select" ON gesign.certificates
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT cui.user_id FROM public.current_user_info() cui)
        OR (
            (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
            AND user_id IN (
                SELECT u.id FROM public.users u
                WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
                  AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
            )
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "certificates_insert_admin" ON gesign.certificates
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "certificates_update_admin" ON gesign.certificates
    FOR UPDATE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "certificates_delete_admin" ON gesign.certificates
    FOR DELETE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "certificates_service_role" ON gesign.certificates
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ── signing_logs ──

CREATE POLICY "signing_logs_select" ON gesign.signing_logs
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT cui.user_id FROM public.current_user_info() cui)
        OR (
            (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
            AND user_id IN (
                SELECT u.id FROM public.users u
                WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
                  AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
            )
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "signing_logs_insert_admin" ON gesign.signing_logs
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "signing_logs_update_admin" ON gesign.signing_logs
    FOR UPDATE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "signing_logs_delete_admin" ON gesign.signing_logs
    FOR DELETE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "signing_logs_service_role" ON gesign.signing_logs
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- J. RLS Policies — eid schema (5 policies each, 10 total)
-- ═══════════════════════════════════════════════════════════════

-- ── national_id_metadata ──

-- SELECT: own OR org(OPERATOR+) OR SUPER_ADMIN
CREATE POLICY "national_id_select" ON eid.national_id_metadata
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT cui.user_id FROM public.current_user_info() cui)
        OR (
            (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
            AND user_id IN (
                SELECT u.id FROM public.users u
                WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
                  AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
            )
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- UPDATE: org(OPERATOR+) OR SUPER_ADMIN (for verification workflow)
CREATE POLICY "national_id_update" ON eid.national_id_metadata
    FOR UPDATE TO authenticated
    USING (
        (
            (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
            AND user_id IN (
                SELECT u.id FROM public.users u
                WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
                  AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
            )
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (
            (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
            AND user_id IN (
                SELECT u.id FROM public.users u
                WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
                  AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
            )
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- INSERT: SUPER_ADMIN only
CREATE POLICY "national_id_insert_admin" ON eid.national_id_metadata
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- DELETE: SUPER_ADMIN only
CREATE POLICY "national_id_delete_admin" ON eid.national_id_metadata
    FOR DELETE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "national_id_service_role" ON eid.national_id_metadata
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ── verification_logs ──

-- SELECT: own OR org(OPERATOR+) OR SUPER_ADMIN
CREATE POLICY "verification_logs_select" ON eid.verification_logs
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT cui.user_id FROM public.current_user_info() cui)
        OR (
            (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
            AND user_id IN (
                SELECT u.id FROM public.users u
                WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
                  AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
            )
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- INSERT: org(OPERATOR+) OR SUPER_ADMIN (for verification results)
CREATE POLICY "verification_logs_insert" ON eid.verification_logs
    FOR INSERT TO authenticated
    WITH CHECK (
        (
            (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
            AND user_id IN (
                SELECT u.id FROM public.users u
                WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
                  AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
            )
        )
        OR (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- UPDATE: SUPER_ADMIN only
CREATE POLICY "verification_logs_update_admin" ON eid.verification_logs
    FOR UPDATE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- DELETE: SUPER_ADMIN only
CREATE POLICY "verification_logs_delete_admin" ON eid.verification_logs
    FOR DELETE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "verification_logs_service_role" ON eid.verification_logs
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- K. RLS Policies — public.organizations (5 policies)
-- ═══════════════════════════════════════════════════════════════

-- SELECT: all authenticated users can see organizations
CREATE POLICY "organizations_select" ON public.organizations
    FOR SELECT TO authenticated
    USING (true);

-- INSERT: SUPER_ADMIN only
CREATE POLICY "organizations_insert_admin" ON public.organizations
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- UPDATE: SUPER_ADMIN only
CREATE POLICY "organizations_update_admin" ON public.organizations
    FOR UPDATE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- DELETE: SUPER_ADMIN only
CREATE POLICY "organizations_delete_admin" ON public.organizations
    FOR DELETE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "organizations_service_role" ON public.organizations
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- L. Grant Changes
-- ═══════════════════════════════════════════════════════════════

-- Revoke anon SELECT on user-data tables (authenticated-only in RBAC model)
REVOKE SELECT ON public.users FROM anon;
REVOKE SELECT ON gesign.certificates FROM anon;
REVOKE SELECT ON gesign.signing_logs FROM anon;
REVOKE SELECT ON eid.national_id_metadata FROM anon;
REVOKE SELECT ON eid.verification_logs FROM anon;

-- Grant UPDATE on eid tables to authenticated (for OPERATOR verification writes)
GRANT UPDATE ON eid.national_id_metadata TO authenticated;
GRANT INSERT ON eid.verification_logs TO authenticated;

-- Organizations grants
GRANT SELECT ON public.organizations TO authenticated;
GRANT ALL ON public.organizations TO service_role;


-- ═══════════════════════════════════════════════════════════════
-- M. Auth Hook — Auto-provision public.users on signup
-- ═══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    _email TEXT;
    _domain TEXT;
    _org_id UUID;
    _role public.user_role;
BEGIN
    _email := NEW.email;

    -- Extract domain from email
    _domain := split_part(_email, '@', 2);

    -- Determine org and role based on email domain
    IF _domain = 'gerege.mn' THEN
        -- Gerege employees get SUPER_ADMIN + assigned to Gerege org
        SELECT id INTO _org_id FROM public.organizations WHERE domain = 'gerege.mn' LIMIT 1;
        _role := 'SUPER_ADMIN';
    ELSE
        -- Try to match org by email domain
        SELECT id INTO _org_id FROM public.organizations WHERE domain = _domain LIMIT 1;
        _role := 'CITIZEN';
    END IF;

    -- Insert into public.users (idempotent)
    INSERT INTO public.users (auth_user_id, email, role, org_id, full_name)
    VALUES (
        NEW.id,
        _email,
        _role,
        _org_id,
        COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', split_part(_email, '@', 1))
    )
    ON CONFLICT (auth_user_id) DO NOTHING;

    RETURN NEW;
END;
$$;

-- Create trigger (drop first for idempotency)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- Grant execute to supabase_auth_admin (GoTrue runs as this role)
GRANT EXECUTE ON FUNCTION public.handle_new_auth_user() TO supabase_auth_admin;


COMMIT;
