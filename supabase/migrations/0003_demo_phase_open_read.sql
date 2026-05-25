-- Wedge-phase RLS: anon (the API w/ the publishable key OR future
-- service-role key) can read everything, can insert notes, can insert
-- activity_events. Real auth replaces this when Supabase Auth is wired
-- (see HANDOFF.md). Treat the schema as semi-public demo data until then.

-- ----- Read access (anon SELECT) -----
drop policy if exists demo_public_read on workspaces;
create policy demo_public_read on workspaces for select using (true);

drop policy if exists demo_public_read on rooms;
create policy demo_public_read on rooms for select using (true);

drop policy if exists demo_public_read on songs;
create policy demo_public_read on songs for select using (deleted_at is null);

drop policy if exists demo_public_read on versions;
create policy demo_public_read on versions for select using (true);

drop policy if exists demo_public_read on file_assets;
create policy demo_public_read on file_assets for select using (true);

drop policy if exists demo_public_read on notes;
create policy demo_public_read on notes for select using (visibility <> 'private');

drop policy if exists demo_public_read on memberships;
create policy demo_public_read on memberships for select using (true);

drop policy if exists demo_public_read on share_links;
create policy demo_public_read on share_links for select using (revoked_at is null);

drop policy if exists demo_public_read on approvals;
create policy demo_public_read on approvals for select using (true);

drop policy if exists demo_public_read on activity_events;
create policy demo_public_read on activity_events for select using (true);

drop policy if exists demo_public_read on users;
create policy demo_public_read on users for select using (true);

alter table users enable row level security;

-- ----- Write access for demo (anon INSERT) -----
drop policy if exists demo_public_insert_notes on notes;
create policy demo_public_insert_notes on notes for insert with check (true);

drop policy if exists demo_public_update_notes on notes;
create policy demo_public_update_notes on notes for update using (true) with check (true);

drop policy if exists demo_public_insert_activity on activity_events;
create policy demo_public_insert_activity on activity_events for insert with check (true);

drop policy if exists demo_public_insert_approvals on approvals;
create policy demo_public_insert_approvals on approvals for insert with check (true);

drop policy if exists demo_public_insert_versions on versions;
create policy demo_public_insert_versions on versions for insert with check (true);

drop policy if exists demo_public_insert_links on share_links;
create policy demo_public_insert_links on share_links for insert with check (true);
