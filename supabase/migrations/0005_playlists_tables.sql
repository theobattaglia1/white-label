-- 0005 — Move Playlists from in-memory seed to real Supabase tables.
--
-- Until now the Playlist + PlaylistItem types defined in packages/shared
-- existed only in the in-memory store (used by demo / seeded data and by
-- the API in single-process mode). Every "playlist" feature shipped over
-- the last few sessions has been demo-only against the live Supabase DB.
--
-- This migration adds the tables, indexes, and RLS policies so playlists
-- become a real first-class entity that survives a server restart.

create table if not exists playlists (
  playlist_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  title text not null,
  description text,
  cover_seed text,
  is_pinned boolean not null default false,
  created_by uuid not null references users(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists playlist_items (
  item_id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references playlists(playlist_id) on delete cascade,
  song_id uuid not null references songs(song_id) on delete cascade,
  position integer not null,
  added_by uuid references users(user_id) on delete set null,
  added_at timestamptz not null default now(),
  unique (playlist_id, song_id),
  unique (playlist_id, position) deferrable initially deferred
);

create index if not exists idx_playlists_workspace on playlists(workspace_id, updated_at desc);
create index if not exists idx_playlist_items_playlist on playlist_items(playlist_id, position);
create index if not exists idx_playlist_items_song on playlist_items(song_id);

alter table playlists enable row level security;
alter table playlist_items enable row level security;

drop policy if exists member_read_playlists on playlists;
create policy member_read_playlists on playlists for select using (can_read_workspace(workspace_id));

drop policy if exists manager_write_playlists on playlists;
create policy manager_write_playlists on playlists for all
  using (can_manage_workspace(workspace_id))
  with check (can_manage_workspace(workspace_id));

drop policy if exists member_read_playlist_items on playlist_items;
create policy member_read_playlist_items on playlist_items for select using (
  exists (
    select 1 from playlists p
    where p.playlist_id = playlist_items.playlist_id
      and can_read_workspace(p.workspace_id)
  )
);

drop policy if exists manager_write_playlist_items on playlist_items;
create policy manager_write_playlist_items on playlist_items for all
  using (
    exists (
      select 1 from playlists p
      where p.playlist_id = playlist_items.playlist_id
        and can_manage_workspace(p.workspace_id)
    )
  )
  with check (
    exists (
      select 1 from playlists p
      where p.playlist_id = playlist_items.playlist_id
        and can_manage_workspace(p.workspace_id)
    )
  );
