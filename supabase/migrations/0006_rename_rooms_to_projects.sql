-- 0006 — Rename rooms → projects (atomic rename; no compat views needed).
--
-- Rationale: producers, artists, labels, and managers all think in "projects,"
-- not "rooms." The architecture-critic confirmed this rename is safe as a single
-- atomic commit. External IDs (room-hudson-ingram-lp, etc.) remain unchanged —
-- they are stable opaque keys, not user-visible labels.
--
-- Changes:
--   - enum room_type → project_type
--   - table rooms → projects; PK column room_id → project_id
--   - FK columns: songs.primary_room_id → primary_project_id
--                  notes.room_id → project_id
--                  activity_events.room_id → project_id
--   - RLS policies renamed accordingly
--   - share_links.target_type check updated: 'room' → 'project'

-- ── 1. Rename enum ────────────────────────────────────────────────────────────
alter type room_type rename to project_type;

-- ── 2. Rename table + PK column ───────────────────────────────────────────────
alter table rooms rename to projects;
alter table projects rename column room_id to project_id;

-- ── 3. Rename FK columns in dependent tables ──────────────────────────────────
alter table songs rename column primary_room_id to primary_project_id;
alter table notes rename column room_id to project_id;
alter table activity_events rename column room_id to project_id;

-- ── 4. Rename RLS policies ────────────────────────────────────────────────────
-- Drop the old policies and recreate with new names.
-- (PostgreSQL has no RENAME POLICY; we must drop+create.)
drop policy if exists member_read_rooms on projects;
drop policy if exists manager_write_rooms on projects;

create policy member_read_projects on projects
  for select
  using (
    workspace_id in (
      select workspace_id from memberships where user_id = auth.uid()
    )
  );

create policy manager_write_projects on projects
  for all
  using (
    workspace_id in (
      select workspace_id from memberships
       where user_id = auth.uid()
         and role in ('owner', 'admin', 'manager')
    )
  );

-- ── 5. Update share_links.target_type constraint ──────────────────────────────
-- Replace 'room' with 'project' in the allowed values.
-- Existing rows with target_type = 'room' must be updated first so the
-- new constraint does not reject them.
update share_links set target_type = 'project' where target_type = 'room';

alter table share_links drop constraint if exists share_links_target_type_check;
alter table share_links
  add constraint share_links_target_type_check
  check (target_type in ('song', 'project', 'playlist'));
