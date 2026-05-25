-- Allow human-friendly external IDs alongside UUID PKs so the existing
-- API routes (/songs/song-midnight, /rooms/room-secret-album, …) keep
-- resolving against the API client's string IDs. Backward-compatible
-- with anything that wants to use UUIDs directly.
alter table workspaces  add column if not exists external_id text unique;
alter table rooms       add column if not exists external_id text unique;
alter table songs       add column if not exists external_id text unique;
alter table versions    add column if not exists external_id text unique;
alter table file_assets add column if not exists external_id text unique;
alter table notes       add column if not exists external_id text unique;
alter table share_links add column if not exists external_id text unique;
alter table users       add column if not exists external_id text unique;

create index if not exists idx_songs_external_id       on songs(external_id);
create index if not exists idx_rooms_external_id       on rooms(external_id);
create index if not exists idx_versions_external_id    on versions(external_id);
create index if not exists idx_file_assets_external_id on file_assets(external_id);
create index if not exists idx_users_external_id       on users(external_id);
create index if not exists idx_share_links_external_id on share_links(external_id);
