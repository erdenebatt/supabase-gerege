-- 03-eid-schema.sql
-- eID schema: national ID metadata and verification audit trail
-- Part of the Gerege AI Ecosystem — Electronic Identity Service

-- ─── National ID Metadata ────────────────────────────────────
-- Citizen electronic identity metadata
-- Sensitive fields are stored encrypted at application level
CREATE TABLE IF NOT EXISTS eid.national_id_metadata (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,

    -- ID document info
    document_type VARCHAR(20) NOT NULL DEFAULT 'national_id'
        CHECK (document_type IN ('national_id', 'passport', 'driver_license', 'residence_permit')),
    document_number VARCHAR(50) NOT NULL,
    issuing_country VARCHAR(3) NOT NULL DEFAULT 'MNG',  -- ISO 3166-1 alpha-3
    issuing_authority VARCHAR(255),

    -- Personal info (from ID document)
    family_name VARCHAR(255) NOT NULL,
    given_name VARCHAR(255) NOT NULL,
    date_of_birth DATE NOT NULL,
    gender VARCHAR(10) CHECK (gender IN ('male', 'female', 'other')),
    nationality VARCHAR(3) DEFAULT 'MNG',

    -- Mongolian-specific
    register_number VARCHAR(10),            -- Mongolian civil registration number (e.g., УА12345678)
    father_name VARCHAR(255),               -- Patronymic (common in Mongolian naming)

    -- Document validity
    issue_date DATE NOT NULL,
    expiry_date DATE NOT NULL,
    -- Note: is_expired computed at query time, not as generated column (CURRENT_DATE is not immutable)

    -- Verification state
    verification_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (verification_status IN ('pending', 'verified', 'rejected', 'expired', 'suspended')),
    verified_at TIMESTAMPTZ,
    verified_by UUID REFERENCES public.users(id),

    -- Document image references (stored in Supabase Storage)
    front_image_path TEXT,
    back_image_path TEXT,
    selfie_image_path TEXT,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_national_id_user_doctype UNIQUE (user_id, document_type)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_national_id_user_id ON eid.national_id_metadata (user_id);
CREATE INDEX IF NOT EXISTS idx_national_id_document_number ON eid.national_id_metadata (document_number);
CREATE INDEX IF NOT EXISTS idx_national_id_register_number ON eid.national_id_metadata (register_number) WHERE register_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_national_id_verification_status ON eid.national_id_metadata (verification_status);
CREATE INDEX IF NOT EXISTS idx_national_id_expiry ON eid.national_id_metadata (expiry_date) WHERE verification_status = 'verified';

CREATE TRIGGER set_national_id_updated_at
    BEFORE UPDATE ON eid.national_id_metadata
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();


-- ─── Verification Logs ───────────────────────────────────────
-- Audit trail for all identity verification operations
CREATE TABLE IF NOT EXISTS eid.verification_logs (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    national_id_record_id UUID REFERENCES eid.national_id_metadata(id) ON DELETE SET NULL,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,

    -- Verification details
    verification_type VARCHAR(30) NOT NULL
        CHECK (verification_type IN (
            'document_ocr',          -- OCR extraction from ID document
            'face_match',            -- Face comparison (selfie vs ID photo)
            'liveness_check',        -- Anti-spoofing liveness detection
            'database_check',        -- Cross-reference with government DB
            'manual_review',         -- Human operator review
            'certificate_verify',    -- Certificate-based identity check
            'nfc_read'               -- NFC chip reading from e-passport/eID
        )),

    -- Result
    status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'success', 'failure', 'error', 'timeout', 'manual_review')),
    confidence_score DECIMAL(5,4),        -- 0.0000 to 1.0000
    failure_reason TEXT,

    -- Provider info (if using external verification service)
    provider VARCHAR(100),                 -- e.g., 'dan_info', 'mongolian_registry'
    provider_request_id VARCHAR(255),
    provider_response JSONB,

    -- Client info
    client_ip INET,
    user_agent TEXT,
    device_fingerprint VARCHAR(255),

    -- Timing
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    duration_ms INTEGER,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_verification_logs_user_id ON eid.verification_logs (user_id);
CREATE INDEX IF NOT EXISTS idx_verification_logs_national_id ON eid.verification_logs (national_id_record_id);
CREATE INDEX IF NOT EXISTS idx_verification_logs_type ON eid.verification_logs (verification_type);
CREATE INDEX IF NOT EXISTS idx_verification_logs_status ON eid.verification_logs (status);
CREATE INDEX IF NOT EXISTS idx_verification_logs_created_at ON eid.verification_logs (created_at DESC);


-- ─── Row Level Security ──────────────────────────────────────
ALTER TABLE eid.national_id_metadata ENABLE ROW LEVEL SECURITY;
ALTER TABLE eid.verification_logs ENABLE ROW LEVEL SECURITY;

-- Users can view their own national ID metadata
CREATE POLICY "Users can view own national ID"
    ON eid.national_id_metadata FOR SELECT
    TO anon, authenticated
    USING (user_id IN (SELECT id FROM public.users WHERE auth_user_id = (select auth.uid())));

-- Service role has full access
CREATE POLICY "Service role has full access to national ID"
    ON eid.national_id_metadata FOR ALL
    TO service_role
    USING (true) WITH CHECK (true);

-- Users can view their own verification logs
CREATE POLICY "Users can view own verification logs"
    ON eid.verification_logs FOR SELECT
    TO anon, authenticated
    USING (user_id IN (SELECT id FROM public.users WHERE auth_user_id = (select auth.uid())));

-- Service role has full access to verification logs
CREATE POLICY "Service role has full access to verification logs"
    ON eid.verification_logs FOR ALL
    TO service_role
    USING (true) WITH CHECK (true);


-- ─── Grants ──────────────────────────────────────────────────
GRANT SELECT ON eid.national_id_metadata TO anon, authenticated;
GRANT ALL ON eid.national_id_metadata TO service_role;

GRANT SELECT ON eid.verification_logs TO anon, authenticated;
GRANT ALL ON eid.verification_logs TO service_role;
