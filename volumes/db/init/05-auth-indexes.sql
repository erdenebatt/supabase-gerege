-- 05-auth-indexes.sql
-- Add missing indexes on auth schema foreign keys.
-- These tables are created by GoTrue, so this runs after service startup.
-- Safe to re-run (uses IF NOT EXISTS).

CREATE INDEX IF NOT EXISTS idx_mfa_challenges_factor_id ON auth.mfa_challenges (factor_id);
CREATE INDEX IF NOT EXISTS idx_saml_relay_states_flow_state_id ON auth.saml_relay_states (flow_state_id);
CREATE INDEX IF NOT EXISTS idx_oauth_authorizations_client_id ON auth.oauth_authorizations (client_id);
CREATE INDEX IF NOT EXISTS idx_oauth_authorizations_user_id ON auth.oauth_authorizations (user_id);
