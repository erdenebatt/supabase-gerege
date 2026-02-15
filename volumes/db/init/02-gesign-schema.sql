-- 02-gesign-schema.sql
-- GeSign schema: digital certificates and signing audit trail
-- Part of the Gerege AI Ecosystem — Digital Signature Service

-- ─── Certificates ────────────────────────────────────────────
-- Digital certificate storage (X.509)
CREATE TABLE IF NOT EXISTS gesign.certificates (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,

    -- Certificate identity
    serial_number VARCHAR(64) UNIQUE NOT NULL,
    common_name VARCHAR(255) NOT NULL,
    subject_dn TEXT NOT NULL,              -- Full distinguished name
    issuer_dn TEXT NOT NULL,               -- Certificate Authority DN

    -- Certificate data
    certificate_pem TEXT NOT NULL,          -- PEM-encoded X.509 certificate
    public_key_pem TEXT NOT NULL,           -- PEM-encoded public key
    key_algorithm VARCHAR(20) NOT NULL DEFAULT 'RSA',
    key_size INTEGER NOT NULL DEFAULT 2048,

    -- Validity
    not_before TIMESTAMPTZ NOT NULL,
    not_after TIMESTAMPTZ NOT NULL,
    -- Note: is_expired computed at query time, not as generated column (now() is not immutable)

    -- Revocation
    is_revoked BOOLEAN NOT NULL DEFAULT false,
    revoked_at TIMESTAMPTZ,
    revocation_reason VARCHAR(50),

    -- Status
    status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'expired', 'revoked', 'suspended', 'pending')),

    -- Usage tracking
    sign_count INTEGER NOT NULL DEFAULT 0,
    last_used_at TIMESTAMPTZ,

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_certificates_user_id ON gesign.certificates (user_id);
CREATE INDEX IF NOT EXISTS idx_certificates_serial ON gesign.certificates (serial_number);
CREATE INDEX IF NOT EXISTS idx_certificates_status ON gesign.certificates (status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_certificates_not_after ON gesign.certificates (not_after);

CREATE TRIGGER set_certificates_updated_at
    BEFORE UPDATE ON gesign.certificates
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();


-- ─── Signing Logs ────────────────────────────────────────────
-- Audit trail for all document signing operations
CREATE TABLE IF NOT EXISTS gesign.signing_logs (
    id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
    certificate_id UUID NOT NULL REFERENCES gesign.certificates(id) ON DELETE RESTRICT,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,

    -- Document info
    document_hash VARCHAR(128) NOT NULL,   -- SHA-256/512 hash of the signed document
    document_name VARCHAR(500),
    document_type VARCHAR(50),             -- 'pdf', 'xml', 'json', etc.
    document_size_bytes BIGINT,

    -- Signature details
    signature_algorithm VARCHAR(50) NOT NULL DEFAULT 'SHA256withRSA',
    signature_value TEXT NOT NULL,          -- Base64-encoded signature
    signature_format VARCHAR(20) NOT NULL DEFAULT 'CAdES'
        CHECK (signature_format IN ('CAdES', 'XAdES', 'PAdES', 'JAdES', 'raw')),

    -- Timestamp
    timestamp_token TEXT,                  -- TSA response (RFC 3161)
    timestamp_authority VARCHAR(255),

    -- Verification
    is_valid BOOLEAN NOT NULL DEFAULT true,
    verification_status VARCHAR(20) NOT NULL DEFAULT 'valid'
        CHECK (verification_status IN ('valid', 'invalid', 'expired', 'revoked', 'unknown')),

    -- Client info
    client_ip INET,
    user_agent TEXT,
    request_id VARCHAR(100),

    -- Metadata
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_signing_logs_certificate_id ON gesign.signing_logs (certificate_id);
CREATE INDEX IF NOT EXISTS idx_signing_logs_user_id ON gesign.signing_logs (user_id);
CREATE INDEX IF NOT EXISTS idx_signing_logs_document_hash ON gesign.signing_logs (document_hash);
CREATE INDEX IF NOT EXISTS idx_signing_logs_created_at ON gesign.signing_logs (created_at DESC);


-- ─── Row Level Security ──────────────────────────────────────
ALTER TABLE gesign.certificates ENABLE ROW LEVEL SECURITY;
ALTER TABLE gesign.signing_logs ENABLE ROW LEVEL SECURITY;

-- Users can view their own certificates
CREATE POLICY "Users can view own certificates"
    ON gesign.certificates FOR SELECT
    USING (user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid()));

-- Service role has full access
CREATE POLICY "Service role has full access to certificates"
    ON gesign.certificates FOR ALL
    USING (auth.role() = 'service_role');

-- Users can view their own signing logs
CREATE POLICY "Users can view own signing logs"
    ON gesign.signing_logs FOR SELECT
    USING (user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid()));

-- Service role has full access to signing logs
CREATE POLICY "Service role has full access to signing logs"
    ON gesign.signing_logs FOR ALL
    USING (auth.role() = 'service_role');


-- ─── Grants ──────────────────────────────────────────────────
GRANT SELECT ON gesign.certificates TO authenticated;
GRANT ALL ON gesign.certificates TO service_role;

GRANT SELECT ON gesign.signing_logs TO authenticated;
GRANT ALL ON gesign.signing_logs TO service_role;
