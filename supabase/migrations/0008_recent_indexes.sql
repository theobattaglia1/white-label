-- 0008 — Indexes supporting the workspace 'recent' feed query.
-- The recent endpoint reads songs ordered by max(song.updated_at,
-- current_version.created_at) — two indexes keep that fast as the
-- workspace grows.

create index if not exists idx_songs_workspace_updated_at
  on songs(workspace_id, updated_at desc);

create index if not exists idx_versions_song_created_at
  on versions(song_id, created_at desc);
