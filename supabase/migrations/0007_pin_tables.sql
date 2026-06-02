-- 0007 — Pin tables: three narrow tables for user-pinned songs, playlists,
--         and projects.
--
-- Design rationale: three narrow tables with real FKs + ON DELETE CASCADE,
-- NOT a polymorphic (entity_type, entity_id) table. Polymorphic gives no
-- referential integrity, no cascade, and produces dangling pin references
-- at scale. Three narrow tables give type-safe queries and cascade behavior
-- for free.
--
-- Scope: private pins only (user_id = auth.uid()). Shared pins are a future
-- iteration. Each table is scoped to (workspace_id, user_id) with a unique
-- constraint on (user_id, <entity>_id) so a user cannot double-pin.

-- ── pinned_songs ─────────────────────────────────────────────────────────────

create table if not exists pinned_songs (
  pin_id        uuid        primary key default gen_random_uuid(),
  workspace_id  uuid        not null references workspaces(workspace_id) on delete cascade,
  user_id       uuid        not null references users(user_id) on delete cascade,
  song_id       uuid        not null references songs(song_id) on delete cascade,
  pinned_at     timestamptz not null default now(),
  unique (user_id, song_id)
);

create index if not exists idx_pinned_songs_user_at
  on pinned_songs (user_id, pinned_at desc);

alter table pinned_songs enable row level security;

drop policy if exists self_read_pinned_songs on pinned_songs;
create policy self_read_pinned_songs on pinned_songs
  for select using (user_id = auth.uid());

drop policy if exists self_write_pinned_songs on pinned_songs;
create policy self_write_pinned_songs on pinned_songs
  for all using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ── pinned_playlists ──────────────────────────────────────────────────────────

create table if not exists pinned_playlists (
  pin_id        uuid        primary key default gen_random_uuid(),
  workspace_id  uuid        not null references workspaces(workspace_id) on delete cascade,
  user_id       uuid        not null references users(user_id) on delete cascade,
  playlist_id   uuid        not null references playlists(playlist_id) on delete cascade,
  pinned_at     timestamptz not null default now(),
  unique (user_id, playlist_id)
);

create index if not exists idx_pinned_playlists_user_at
  on pinned_playlists (user_id, pinned_at desc);

alter table pinned_playlists enable row level security;

drop policy if exists self_read_pinned_playlists on pinned_playlists;
create policy self_read_pinned_playlists on pinned_playlists
  for select using (user_id = auth.uid());

drop policy if exists self_write_pinned_playlists on pinned_playlists;
create policy self_write_pinned_playlists on pinned_playlists
  for all using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ── pinned_projects ───────────────────────────────────────────────────────────

create table if not exists pinned_projects (
  pin_id        uuid        primary key default gen_random_uuid(),
  workspace_id  uuid        not null references workspaces(workspace_id) on delete cascade,
  user_id       uuid        not null references users(user_id) on delete cascade,
  project_id    uuid        not null references projects(project_id) on delete cascade,
  pinned_at     timestamptz not null default now(),
  unique (user_id, project_id)
);

create index if not exists idx_pinned_projects_user_at
  on pinned_projects (user_id, pinned_at desc);

alter table pinned_projects enable row level security;

drop policy if exists self_read_pinned_projects on pinned_projects;
create policy self_read_pinned_projects on pinned_projects
  for select using (user_id = auth.uid());

drop policy if exists self_write_pinned_projects on pinned_projects;
create policy self_write_pinned_projects on pinned_projects
  for all using (user_id = auth.uid())
  with check (user_id = auth.uid());
