-- 0014_workspace_join_links.sql
-- =========================================================================
-- Shareable join links — owner generates a token from the iOS app, shares
-- it however they like (iMessage, etc.). Anyone with the link can create an
-- account and land in the workspace automatically.
--
-- No email pre-registration required. The link IS the trust gate.
-- =========================================================================

CREATE TABLE IF NOT EXISTS workspace_join_links (
  link_id      uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  workspace_id uuid        NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
  token        text        NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(24), 'hex'),
  role         member_role NOT NULL DEFAULT 'viewer',
  created_by   text,         -- external_id of the generating user
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz   -- NULL = never expires
);

-- Service-role only writes; the claim endpoint uses the service key.
ALTER TABLE workspace_join_links ENABLE ROW LEVEL SECURITY;
