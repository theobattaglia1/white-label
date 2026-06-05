-- 0006_close_demo_read_policies.sql
-- =========================================================================
-- Close the demo-phase OPEN READ policies introduced in 0003.
--
-- 0003 added `demo_public_read` policies (`USING (true)`, or near-true) to the
-- `public`/anon role on EVERY table: workspaces, rooms, songs, versions,
-- file_assets, notes, memberships, share_links, approvals, activity_events,
-- users. RLS policies are PERMISSIVE (OR-combined), so these `USING (true)`
-- grants override the membership-gated `*_read_*` policies that 0001 created
-- (member_read_songs, member_read_versions, member_read_file_assets,
-- member_read_notes, member_read_memberships, member_read_rooms, …). The net
-- effect: anyone holding the publishable anon key — which ships in the web
-- bundle and the iOS binary — can read the ENTIRE database directly via
-- Supabase PostgREST, bypassing the API. For a workspace of UNRELEASED music,
-- that exposes every song title, version, storage key (key_original /
-- playback_url), note body, share-link, and member email. This migration
-- removes those grants so 0001's membership-gated read policies become the
-- SOLE read gate again.
--
-- SAFETY — why this is behaviour-preserving for the live app:
--   * The API reads/writes with the SERVICE ROLE key (apps/api/src/supabase.ts),
--     which BYPASSES RLS entirely. store.hydrate() / loadSnapshotFromSupabase()
--     are unaffected. Every API surface keeps working exactly as before.
--   * No client reads Supabase directly today — the web app uses @supabase/
--     supabase-js for AUTH ONLY (apps/web/src/auth.ts); all data reads route
--     through the API. iOS likewise reads via the API. So removing the anon
--     read grant changes no current app behaviour; it only closes the
--     cross-tenant exfiltration hole for the (correctly public) anon key.
--   * 0001's member_read_* policies (predicated on can_read_workspace(), which
--     0005 rewired to resolve identity via users.auth_uid) remain in place and
--     become the effective gate the moment these demo policies are gone.
--
-- Apply AFTER 0005. Reversible: re-running 0003 restores the open-read state.
-- =========================================================================

drop policy if exists demo_public_read on workspaces;
drop policy if exists demo_public_read on rooms;
drop policy if exists demo_public_read on songs;
drop policy if exists demo_public_read on versions;
drop policy if exists demo_public_read on file_assets;
drop policy if exists demo_public_read on notes;
drop policy if exists demo_public_read on memberships;
drop policy if exists demo_public_read on share_links;
drop policy if exists demo_public_read on approvals;
drop policy if exists demo_public_read on activity_events;
drop policy if exists demo_public_read on users;
