-- 0004_close_demo_write_policies.sql
-- =========================================================================
-- Close the demo-phase OPEN WRITE policies introduced in 0003.
--
-- 0003 added `demo_public_*` policies with `WITH CHECK (true)` granting the
-- `public` role (i.e. anyone holding the publishable anon key) INSERT on
-- notes/versions/approvals/share_links/activity_events and UPDATE on notes —
-- across EVERY workspace. That bypasses the membership-gated write policies
-- that 0001 already created (member_write_notes, producer_write_versions,
-- manager_write_links, producer_write_songs, manager_write_rooms,
-- admin_write_memberships, producer_write_file_assets). This migration removes
-- the open policies so those 0001 policies become the SOLE write gate for the
-- anon/authenticated roles, and fills the two gaps 0001 left (approvals had no
-- membership write policy; activity_events' insert was open to `public`).
--
-- SAFETY — why this is behaviour-preserving for the live app:
--   * The API writes with the SERVICE ROLE key (apps/api/src/supabase.ts),
--     which BYPASSES RLS entirely. Every server-side write (persistNote, etc.)
--     is unaffected by any policy change here.
--   * No client writes to Supabase directly today — all mutations route through
--     the API. So removing the anon write grant changes no current behaviour;
--     it only closes the cross-tenant hole for the (correctly public) anon key.
--   * Read policies (`demo_public_read` on each table) are intentionally LEFT
--     in place — public read is acceptable for the current demo phase. Tighten
--     reads in a later migration when per-tenant read isolation is required.
--
-- Ordering: apply BEFORE 0005. The new policies below reference
-- current_workspace_role()/can_read_workspace() by name; 0005 rewrites those
-- functions to resolve identity via users.auth_uid, and the policies pick up the
-- new semantics automatically (no edit here needed when 0005 lands).
-- =========================================================================

-- notes — drop open insert + update; 0001's member_write_notes remains.
drop policy if exists demo_public_insert_notes on notes;
drop policy if exists demo_public_update_notes on notes;

-- versions — drop open insert; 0001's producer_write_versions remains.
drop policy if exists demo_public_insert_versions on versions;

-- share_links — drop open insert; 0001's manager_write_links remains.
drop policy if exists demo_public_insert_links on share_links;

-- approvals — drop open insert. 0001 created NO membership write policy for
-- approvals, so add one now: a member with a decision-making role on the
-- approved version's song's workspace may write approvals. (Guest approvals via
-- a share link go through the API/service-role and are unaffected.)
drop policy if exists demo_public_insert_approvals on approvals;
drop policy if exists member_write_approvals on approvals;
create policy member_write_approvals on approvals for all
  using (
    exists (
      select 1
      from versions v
      join songs s on s.song_id = v.song_id
      where v.version_id = approvals.version_id
        and current_workspace_role(s.workspace_id) in
            ('owner','admin','manager','producer','engineer','artist','anr')
    )
  )
  with check (
    exists (
      select 1
      from versions v
      join songs s on s.song_id = v.song_id
      where v.version_id = approvals.version_id
        and current_workspace_role(s.workspace_id) in
            ('owner','admin','manager','producer','engineer','artist','anr')
    )
  );

-- activity_events — BOTH 0001's service_insert_activity and 0003's
-- demo_public_insert_activity are `WITH CHECK (true)` for `public`, letting anon
-- forge activity for any workspace. Replace both with a membership-gated insert:
-- any member of the workspace may log activity for it. The API logs activity via
-- the service-role key (RLS-exempt), so this only constrains the anon path.
drop policy if exists demo_public_insert_activity on activity_events;
drop policy if exists service_insert_activity on activity_events;
drop policy if exists member_insert_activity on activity_events;
create policy member_insert_activity on activity_events for insert
  with check (can_read_workspace(workspace_id));
