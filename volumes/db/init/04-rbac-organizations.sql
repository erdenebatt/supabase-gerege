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
VALUES ('Gerege', 'gerege.mn', 'active')
ON CONFLICT (domain) DO NOTHING;


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
-- public.users
DROP POLICY IF EXISTS "Users can view own profile" ON public.users;
DROP POLICY IF EXISTS "Users can update own profile" ON public.users;
DROP POLICY IF EXISTS "Service role has full access to users" ON public.users;

-- public.user_mfa_settings
DROP POLICY IF EXISTS "Users can manage own MFA settings" ON public.user_mfa_settings;
DROP POLICY IF EXISTS "Service role has full access to MFA settings" ON public.user_mfa_settings;

-- public.user_totp
DROP POLICY IF EXISTS "Users can manage own TOTP" ON public.user_totp;
DROP POLICY IF EXISTS "Service role has full access to TOTP" ON public.user_totp;

-- public.mfa_recovery_codes
DROP POLICY IF EXISTS "Users can manage own recovery codes" ON public.mfa_recovery_codes;
DROP POLICY IF EXISTS "Service role has full access to recovery codes" ON public.mfa_recovery_codes;

-- gesign.certificates
DROP POLICY IF EXISTS "Users can view own certificates" ON gesign.certificates;
DROP POLICY IF EXISTS "Service role has full access to certificates" ON gesign.certificates;

-- gesign.signing_logs
DROP POLICY IF EXISTS "Users can view own signing logs" ON gesign.signing_logs;
DROP POLICY IF EXISTS "Service role has full access to signing logs" ON gesign.signing_logs;

-- eid.national_id_metadata
DROP POLICY IF EXISTS "Users can view own national ID" ON eid.national_id_metadata;
DROP POLICY IF EXISTS "Service role has full access to national ID" ON eid.national_id_metadata;

-- eid.verification_logs
DROP POLICY IF EXISTS "Users can view own verification logs" ON eid.verification_logs;
DROP POLICY IF EXISTS "Service role has full access to verification logs" ON eid.verification_logs;


-- ═══════════════════════════════════════════════════════════════
-- G. New RLS Policies — public.users
-- ═══════════════════════════════════════════════════════════════

-- G1. Own profile: every authenticated user can SELECT their own row
CREATE POLICY "users_select_own" ON public.users
    FOR SELECT TO authenticated
    USING (auth_user_id = (SELECT auth.uid()));

-- G2. ORG_ADMIN can SELECT users in their org
CREATE POLICY "users_select_org" ON public.users
    FOR SELECT TO authenticated
    USING (
        org_id IS NOT NULL
        AND org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
        AND (SELECT cui.role FROM public.current_user_info() cui) >= 'ORG_ADMIN'::public.user_role
    );

-- G3. SUPER_ADMIN can SELECT all users
CREATE POLICY "users_select_all" ON public.users
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G4. Own profile: every authenticated user can UPDATE their own row
CREATE POLICY "users_update_own" ON public.users
    FOR UPDATE TO authenticated
    USING (auth_user_id = (SELECT auth.uid()))
    WITH CHECK (auth_user_id = (SELECT auth.uid()));

-- G5. ORG_ADMIN can UPDATE users in their org
CREATE POLICY "users_update_org" ON public.users
    FOR UPDATE TO authenticated
    USING (
        org_id IS NOT NULL
        AND org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
        AND (SELECT cui.role FROM public.current_user_info() cui) >= 'ORG_ADMIN'::public.user_role
    )
    WITH CHECK (
        org_id IS NOT NULL
        AND org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
        AND (SELECT cui.role FROM public.current_user_info() cui) >= 'ORG_ADMIN'::public.user_role
    );

-- G6. SUPER_ADMIN can UPDATE all users
CREATE POLICY "users_update_all" ON public.users
    FOR UPDATE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G7. SUPER_ADMIN can INSERT users
CREATE POLICY "users_insert_admin" ON public.users
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G8. SUPER_ADMIN can DELETE users
CREATE POLICY "users_delete_admin" ON public.users
    FOR DELETE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- G9. Service role bypass
CREATE POLICY "users_service_role" ON public.users
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- H. New RLS Policies — MFA Tables (own-only + service_role)
-- ═══════════════════════════════════════════════════════════════

-- user_mfa_settings
CREATE POLICY "mfa_settings_own" ON public.user_mfa_settings
    FOR ALL TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui))
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "mfa_settings_service_role" ON public.user_mfa_settings
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- SUPER_ADMIN can SELECT other users' MFA settings
CREATE POLICY "mfa_settings_select_admin" ON public.user_mfa_settings
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- user_totp
CREATE POLICY "totp_own" ON public.user_totp
    FOR ALL TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui))
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "totp_service_role" ON public.user_totp
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

CREATE POLICY "totp_select_admin" ON public.user_totp
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

-- mfa_recovery_codes
CREATE POLICY "recovery_codes_own" ON public.mfa_recovery_codes
    FOR ALL TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui))
    WITH CHECK (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

CREATE POLICY "recovery_codes_service_role" ON public.mfa_recovery_codes
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

CREATE POLICY "recovery_codes_select_admin" ON public.mfa_recovery_codes
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );


-- ═══════════════════════════════════════════════════════════════
-- I. New RLS Policies — gesign schema
-- ═══════════════════════════════════════════════════════════════

-- certificates: own SELECT
CREATE POLICY "certificates_select_own" ON gesign.certificates
    FOR SELECT TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

-- certificates: OPERATOR+ can SELECT within their org
CREATE POLICY "certificates_select_org" ON gesign.certificates
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
        AND user_id IN (
            SELECT u.id FROM public.users u
            WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
              AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
        )
    );

-- certificates: SUPER_ADMIN full access
CREATE POLICY "certificates_all_admin" ON gesign.certificates
    FOR ALL TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "certificates_service_role" ON gesign.certificates
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- signing_logs: own SELECT
CREATE POLICY "signing_logs_select_own" ON gesign.signing_logs
    FOR SELECT TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

-- signing_logs: OPERATOR+ can SELECT within their org
CREATE POLICY "signing_logs_select_org" ON gesign.signing_logs
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
        AND user_id IN (
            SELECT u.id FROM public.users u
            WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
              AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
        )
    );

-- signing_logs: SUPER_ADMIN full access
CREATE POLICY "signing_logs_all_admin" ON gesign.signing_logs
    FOR ALL TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "signing_logs_service_role" ON gesign.signing_logs
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- J. New RLS Policies — eid schema
-- ═══════════════════════════════════════════════════════════════

-- national_id_metadata: own SELECT
CREATE POLICY "national_id_select_own" ON eid.national_id_metadata
    FOR SELECT TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

-- national_id_metadata: OPERATOR+ can SELECT within their org
CREATE POLICY "national_id_select_org" ON eid.national_id_metadata
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
        AND user_id IN (
            SELECT u.id FROM public.users u
            WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
              AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
        )
    );

-- national_id_metadata: OPERATOR+ can UPDATE within their org (for verification)
CREATE POLICY "national_id_update_org" ON eid.national_id_metadata
    FOR UPDATE TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
        AND user_id IN (
            SELECT u.id FROM public.users u
            WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
              AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
        )
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
        AND user_id IN (
            SELECT u.id FROM public.users u
            WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
              AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
        )
    );

-- national_id_metadata: SUPER_ADMIN full access
CREATE POLICY "national_id_all_admin" ON eid.national_id_metadata
    FOR ALL TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "national_id_service_role" ON eid.national_id_metadata
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- verification_logs: own SELECT
CREATE POLICY "verification_logs_select_own" ON eid.verification_logs
    FOR SELECT TO authenticated
    USING (user_id = (SELECT cui.user_id FROM public.current_user_info() cui));

-- verification_logs: OPERATOR+ can SELECT within their org
CREATE POLICY "verification_logs_select_org" ON eid.verification_logs
    FOR SELECT TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
        AND user_id IN (
            SELECT u.id FROM public.users u
            WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
              AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
        )
    );

-- verification_logs: OPERATOR+ can INSERT within their org (for verification results)
CREATE POLICY "verification_logs_insert_org" ON eid.verification_logs
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) >= 'OPERATOR'::public.user_role
        AND user_id IN (
            SELECT u.id FROM public.users u
            WHERE u.org_id = (SELECT cui.org_id FROM public.current_user_info() cui)
              AND (SELECT cui.org_id FROM public.current_user_info() cui) IS NOT NULL
        )
    );

-- verification_logs: SUPER_ADMIN full access
CREATE POLICY "verification_logs_all_admin" ON eid.verification_logs
    FOR ALL TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    );

CREATE POLICY "verification_logs_service_role" ON eid.verification_logs
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════
-- K. Organizations RLS Policies
-- ═══════════════════════════════════════════════════════════════

-- All authenticated users can see organizations
CREATE POLICY "organizations_select_authenticated" ON public.organizations
    FOR SELECT TO authenticated
    USING (true);

-- SUPER_ADMIN can manage organizations
CREATE POLICY "organizations_all_admin" ON public.organizations
    FOR ALL TO authenticated
    USING (
        (SELECT cui.role FROM public.current_user_info() cui) = 'SUPER_ADMIN'::public.user_role
    )
    WITH CHECK (
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
