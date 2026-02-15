-- 01-public-schema.sql
-- Public schema: users, MFA settings, TOTP, recovery codes
-- Part of the Gerege AI Ecosystem "Spine" database

-- ─── Users Table ─────────────────────────────────────────────
-- Central user registry for the Gerege ecosystem
-- Extends Supabase auth.users with application-level profile data
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    auth_user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Identity
    email CITEXT UNIQUE NOT NULL,
    phone VARCHAR(20),
    full_name VARCHAR(255),
    display_name VARCHAR(100),
    avatar_url TEXT,

    -- Mongolian-specific fields
    register_number VARCHAR(10),         -- Mongolian civil registration number
    national_id VARCHAR(20),             -- National ID card number

    -- Organization
    organization VARCHAR(255),
    department VARCHAR(255),
    position VARCHAR(255),

    -- Status
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_verified BOOLEAN NOT NULL DEFAULT false,
    role VARCHAR(50) NOT NULL DEFAULT 'user',

    -- MFA summary flags (denormalized for quick checks)
    mfa_enabled BOOLEAN NOT NULL DEFAULT false,
    mfa_method VARCHAR(20) DEFAULT NULL,  -- 'totp', 'passkey', 'push', or NULL

    -- Metadata
    metadata JSONB DEFAULT '{}',
    last_sign_in_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_users_email ON public.users (email);
CREATE INDEX IF NOT EXISTS idx_users_auth_user_id ON public.users (auth_user_id);
CREATE INDEX IF NOT EXISTS idx_users_register_number ON public.users (register_number) WHERE register_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_role ON public.users (role);
CREATE INDEX IF NOT EXISTS idx_users_is_active ON public.users (is_active) WHERE is_active = true;

-- Updated_at trigger
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_users_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();


-- ─── User MFA Settings ──────────────────────────────────────
-- Per-user MFA configuration (what methods are enabled)
CREATE TABLE IF NOT EXISTS public.user_mfa_settings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    -- Method toggles
    totp_enabled BOOLEAN NOT NULL DEFAULT false,
    passkey_enabled BOOLEAN NOT NULL DEFAULT false,
    push_enabled BOOLEAN NOT NULL DEFAULT false,

    -- Enforcement
    require_mfa BOOLEAN NOT NULL DEFAULT false,
    preferred_method VARCHAR(20) DEFAULT 'totp',

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_user_mfa_settings_user UNIQUE (user_id)
);

CREATE TRIGGER set_user_mfa_settings_updated_at
    BEFORE UPDATE ON public.user_mfa_settings
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();


-- ─── User TOTP ───────────────────────────────────────────────
-- TOTP secrets stored with AES-256-GCM encryption
-- The actual encryption/decryption happens at the application layer
CREATE TABLE IF NOT EXISTS public.user_totp (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    -- Encrypted TOTP secret (AES-256-GCM at application level)
    encrypted_secret TEXT NOT NULL,
    encryption_iv TEXT NOT NULL,           -- Initialization vector
    encryption_tag TEXT NOT NULL,          -- GCM authentication tag

    -- TOTP parameters
    algorithm VARCHAR(10) NOT NULL DEFAULT 'SHA1',
    digits INTEGER NOT NULL DEFAULT 6,
    period INTEGER NOT NULL DEFAULT 30,

    -- Status
    is_verified BOOLEAN NOT NULL DEFAULT false,  -- User has confirmed setup
    verified_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_user_totp_user UNIQUE (user_id)
);

CREATE TRIGGER set_user_totp_updated_at
    BEFORE UPDATE ON public.user_totp
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();


-- ─── MFA Recovery Codes ──────────────────────────────────────
-- One-time-use recovery codes, stored as SHA-256 hashes
CREATE TABLE IF NOT EXISTS public.mfa_recovery_codes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    -- SHA-256 hash of the recovery code (never store plaintext)
    code_hash TEXT NOT NULL,

    -- Tracking
    is_used BOOLEAN NOT NULL DEFAULT false,
    used_at TIMESTAMPTZ,
    used_ip INET,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_recovery_codes_user_id ON public.mfa_recovery_codes (user_id);
CREATE INDEX IF NOT EXISTS idx_recovery_codes_unused ON public.mfa_recovery_codes (user_id, is_used) WHERE is_used = false;


-- ─── Row Level Security ──────────────────────────────────────
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_mfa_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_totp ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mfa_recovery_codes ENABLE ROW LEVEL SECURITY;

-- Users can read their own profile
CREATE POLICY "Users can view own profile"
    ON public.users FOR SELECT
    USING (auth.uid() = auth_user_id);

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
    ON public.users FOR UPDATE
    USING (auth.uid() = auth_user_id);

-- Service role has full access
CREATE POLICY "Service role has full access to users"
    ON public.users FOR ALL
    USING (auth.role() = 'service_role');

-- MFA settings: users can manage their own
CREATE POLICY "Users can manage own MFA settings"
    ON public.user_mfa_settings FOR ALL
    USING (user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid()));

CREATE POLICY "Service role has full access to MFA settings"
    ON public.user_mfa_settings FOR ALL
    USING (auth.role() = 'service_role');

-- TOTP: users can manage their own
CREATE POLICY "Users can manage own TOTP"
    ON public.user_totp FOR ALL
    USING (user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid()));

CREATE POLICY "Service role has full access to TOTP"
    ON public.user_totp FOR ALL
    USING (auth.role() = 'service_role');

-- Recovery codes: users can manage their own
CREATE POLICY "Users can manage own recovery codes"
    ON public.mfa_recovery_codes FOR ALL
    USING (user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid()));

CREATE POLICY "Service role has full access to recovery codes"
    ON public.mfa_recovery_codes FOR ALL
    USING (auth.role() = 'service_role');


-- ─── Grants ──────────────────────────────────────────────────
GRANT SELECT ON public.users TO anon;
GRANT SELECT, INSERT, UPDATE ON public.users TO authenticated;
GRANT ALL ON public.users TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_mfa_settings TO authenticated;
GRANT ALL ON public.user_mfa_settings TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_totp TO authenticated;
GRANT ALL ON public.user_totp TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.mfa_recovery_codes TO authenticated;
GRANT ALL ON public.mfa_recovery_codes TO service_role;
