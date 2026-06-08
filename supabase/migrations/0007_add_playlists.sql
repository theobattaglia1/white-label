-- Migration 0007: add playlists and playlist_items tables
-- workspace_id / user_id / song_id are uuid in the DB (text in the in-memory layer).

create table if not exists playlists (
  playlist_id     uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references workspaces(workspace_id) on delete cascade,
  owner_user_id   uuid references users(user_id) on delete set null,
  external_id     text unique,
  title           text not null,
  description     text,
  cover_seed      text not null default '',
  is_pinned       boolean not null default false,
  created_by      uuid not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table if not exists playlist_items (
  playlist_item_id  uuid primary key default gen_random_uuid(),
  playlist_id       uuid not null references playlists(playlist_id) on delete cascade,
  song_id           uuid not null references songs(song_id) on delete cascade,
  external_id       text unique,
  position          integer not null default 0,
  added_by          uuid not null,
  added_at          timestamptz not null default now(),
  note              text,
  unique (playlist_id, song_id)
);

create index if not exists idx_playlists_workspace on playlists(workspace_id);
create index if not exists idx_playlist_items_playlist on playlist_items(playlist_id);
create index if not exists idx_playlists_external_id on playlists(external_id);
create index if not exists idx_playlist_items_external_id on playlist_items(external_id);

alter table playlists enable row level security;
alter table playlist_items enable row level security;

-- Match the open-read / authenticated-write pattern from migration 0006
do $$ begin
  if not exists (select 1 from pg_policies where tablename='playlists' and policyname='playlists_read') then
    create policy "playlists_read" on playlists for select using (auth.role() = 'authenticated' or auth.role() = 'service_role');
  end if;
  if not exists (select 1 from pg_policies where tablename='playlists' and policyname='playlists_write') then
    create policy "playlists_write" on playlists for all using (auth.role() = 'authenticated' or auth.role() = 'service_role');
  end if;
  if not exists (select 1 from pg_policies where tablename='playlist_items' and policyname='playlist_items_read') then
    create policy "playlist_items_read" on playlist_items for select using (auth.role() = 'authenticated' or auth.role() = 'service_role');
  end if;
  if not exists (select 1 from pg_policies where tablename='playlist_items' and policyname='playlist_items_write') then
    create policy "playlist_items_write" on playlist_items for all using (auth.role() = 'authenticated' or auth.role() = 'service_role');
  end if;
end $$;
