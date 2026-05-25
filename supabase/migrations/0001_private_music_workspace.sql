create extension if not exists pgcrypto;
create extension if not exists citext;
create extension if not exists vector;

do $$ begin
  create type plan_type as enum ('free','creator','producer','team','label');
exception when duplicate_object then null; end $$;
do $$ begin
  create type member_role as enum ('owner','admin','manager','producer','engineer','artist','anr','viewer','guest');
exception when duplicate_object then null; end $$;
do $$ begin
  create type room_type as enum ('project','producer_delivery','album_ep','anr','pitch','submission_portal','release','inner_circle','archive');
exception when duplicate_object then null; end $$;
do $$ begin
  create type version_type as enum ('demo','rough','mix','master','clean','explicit','instrumental','acapella','tv_track','sped_up','slowed','alt_arrangement','reference','stem_derived');
exception when duplicate_object then null; end $$;
do $$ begin
  create type note_scope as enum ('song','version');
exception when duplicate_object then null; end $$;
do $$ begin
  create type note_status as enum ('open','resolved');
exception when duplicate_object then null; end $$;
do $$ begin
  create type note_visibility as enum ('everyone','internal','private');
exception when duplicate_object then null; end $$;
do $$ begin
  create type approval_state as enum ('approved','revision_requested','passed');
exception when duplicate_object then null; end $$;
do $$ begin
  create type link_access as enum ('public','password','identity_required');
exception when duplicate_object then null; end $$;
do $$ begin
  create type version_policy as enum ('latest_only','full_history');
exception when duplicate_object then null; end $$;
do $$ begin
  create type download_policy as enum ('none','current','all');
exception when duplicate_object then null; end $$;

create table if not exists users (
  user_id uuid primary key default gen_random_uuid(),
  email citext unique not null,
  display_name text,
  avatar_url text,
  auth_provider text,
  two_factor_enabled boolean not null default false,
  notification_preferences jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists workspaces (
  workspace_id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_user_id uuid not null references users(user_id),
  plan_type plan_type not null default 'free',
  storage_quota_bytes bigint not null default 5368709120,
  used_storage_bytes bigint not null default 0,
  billing_status text not null default 'active',
  default_link_policy jsonb,
  default_naming_convention jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists memberships (
  membership_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  user_id uuid not null references users(user_id) on delete cascade,
  role member_role not null default 'viewer',
  created_at timestamptz not null default now(),
  unique (workspace_id, user_id)
);

create table if not exists rooms (
  room_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  type room_type not null default 'project',
  title text not null,
  description text,
  visibility text not null default 'workspace',
  status text not null default 'active',
  default_version_visibility version_policy not null default 'full_history',
  default_download_policy download_policy not null default 'none',
  due_date date,
  created_by uuid not null references users(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists file_assets (
  asset_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  original_filename text not null,
  normalized_filename text,
  key_original text not null,
  key_flac text,
  key_aac_256 text,
  key_aac_128 text,
  key_waveform_json text,
  key_stems_zip text,
  mime_type text,
  file_size_bytes bigint,
  checksum_sha256 text,
  duration_ms integer,
  sample_rate integer,
  bit_depth integer,
  loudness_lufs numeric(6,2),
  true_peak_db numeric(6,2),
  virus_scan_status text not null default 'pending',
  transcoding_status text not null default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists songs (
  song_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  primary_room_id uuid references rooms(room_id) on delete set null,
  title text not null,
  artist_display_name text,
  project_name text,
  status text not null default 'in_progress',
  current_version_id uuid,
  approved_version_id uuid,
  bpm integer,
  song_key text,
  explicit_flag boolean default false,
  genre_tags text[] default '{}',
  mood_tags text[] default '{}',
  instrument_tags text[] default '{}',
  lyric_theme_tags text[] default '{}',
  release_readiness_status text default 'not_ready',
  deleted_at timestamptz,
  created_by uuid not null references users(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists versions (
  version_id uuid primary key default gen_random_uuid(),
  song_id uuid not null references songs(song_id) on delete cascade,
  version_number integer not null,
  version_label text,
  type version_type not null default 'mix',
  parent_version_id uuid references versions(version_id),
  is_current boolean not null default false,
  is_approved boolean not null default false,
  uploaded_by uuid not null references users(user_id),
  file_asset_id uuid not null references file_assets(asset_id),
  created_at timestamptz not null default now(),
  unique (song_id, version_number)
);

do $$ begin
  alter table songs add constraint fk_current_version foreign key (current_version_id) references versions(version_id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table songs add constraint fk_approved_version foreign key (approved_version_id) references versions(version_id) on delete set null;
exception when duplicate_object then null; end $$;

create table if not exists notes (
  note_id uuid primary key default gen_random_uuid(),
  song_id uuid not null references songs(song_id) on delete cascade,
  anchor_version_id uuid not null references versions(version_id),
  room_id uuid references rooms(room_id) on delete set null,
  author_user_id uuid references users(user_id),
  author_guest_label text,
  body text,
  voice_asset_id uuid references file_assets(asset_id),
  scope note_scope not null default 'song',
  visibility note_visibility not null default 'everyone',
  timestamp_start_ms integer,
  timestamp_end_ms integer,
  timestamp_uncertain boolean not null default false,
  assigned_to_user_id uuid references users(user_id),
  assigned_to_role member_role,
  priority text default 'normal',
  status note_status not null default 'open',
  resolved_by uuid references users(user_id),
  resolved_at timestamptz,
  resolved_on_version_id uuid references versions(version_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists mentions (
  mention_id uuid primary key default gen_random_uuid(),
  note_id uuid not null references notes(note_id) on delete cascade,
  mentioned_user_id uuid references users(user_id),
  mentioned_role member_role,
  notification_status text not null default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists tasks (
  task_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  room_id uuid references rooms(room_id) on delete set null,
  song_id uuid references songs(song_id) on delete cascade,
  version_id uuid references versions(version_id) on delete set null,
  source_note_id uuid references notes(note_id) on delete set null,
  title text not null,
  description text,
  assigned_to_user_id uuid references users(user_id),
  assigned_to_role member_role,
  due_date date,
  status text not null default 'open',
  priority text default 'normal',
  created_by uuid references users(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists approvals (
  approval_id uuid primary key default gen_random_uuid(),
  version_id uuid not null references versions(version_id) on delete cascade,
  actor_user_id uuid references users(user_id),
  actor_guest_label text,
  state approval_state not null,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists share_links (
  link_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  target_type text not null check (target_type in ('song','room')),
  target_id uuid not null,
  token_hash text not null unique,
  link_name text,
  access_mode link_access not null default 'public',
  password_hash text,
  expires_at timestamptz,
  download_policy download_policy not null default 'none',
  version_policy version_policy not null default 'latest_only',
  requires_identity boolean not null default false,
  watermark_enabled boolean not null default true,
  allow_comments boolean not null default true,
  allow_approval boolean not null default false,
  allow_forwarding boolean not null default true,
  created_by uuid references users(user_id),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists activity_events (
  event_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  actor_user_id uuid references users(user_id),
  actor_recipient_label text,
  event_type text not null,
  target_type text,
  target_id uuid,
  song_id uuid references songs(song_id) on delete set null,
  version_id uuid references versions(version_id) on delete set null,
  link_id uuid references share_links(link_id) on delete set null,
  metadata jsonb default '{}',
  ip_hash text,
  user_agent_hash text,
  created_at timestamptz not null default now()
);

create table if not exists notifications (
  notification_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(user_id) on delete cascade,
  type text not null,
  payload jsonb not null default '{}',
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists saved_views (
  view_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  user_id uuid references users(user_id),
  name text not null,
  filter jsonb not null,
  created_at timestamptz not null default now()
);

-- Reserved for the future. The vector extension is installed, but similarity is intentionally not implemented.
create table if not exists audio_embeddings_reserved (
  reserved_id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function current_workspace_role(target_workspace_id uuid)
returns member_role
language sql
stable
security definer
set search_path = public
as $$
  select role
  from memberships
  where workspace_id = target_workspace_id
    and user_id = auth.uid()
  limit 1
$$;

create or replace function can_read_workspace(target_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from memberships
    where workspace_id = target_workspace_id
      and user_id = auth.uid()
  )
$$;

create or replace function can_manage_workspace(target_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select current_workspace_role(target_workspace_id) in ('owner','admin','manager')
$$;

alter table workspaces enable row level security;
alter table memberships enable row level security;
alter table rooms enable row level security;
alter table file_assets enable row level security;
alter table songs enable row level security;
alter table versions enable row level security;
alter table notes enable row level security;
alter table mentions enable row level security;
alter table tasks enable row level security;
alter table approvals enable row level security;
alter table share_links enable row level security;
alter table activity_events enable row level security;
alter table notifications enable row level security;
alter table saved_views enable row level security;
alter table audio_embeddings_reserved enable row level security;

drop policy if exists workspace_member_read_workspaces on workspaces;
create policy workspace_member_read_workspaces on workspaces
  for select using (can_read_workspace(workspace_id));

drop policy if exists workspace_admin_update_workspaces on workspaces;
create policy workspace_admin_update_workspaces on workspaces
  for update using (can_manage_workspace(workspace_id))
  with check (can_manage_workspace(workspace_id));

drop policy if exists member_read_memberships on memberships;
create policy member_read_memberships on memberships
  for select using (can_read_workspace(workspace_id));

drop policy if exists admin_write_memberships on memberships;
create policy admin_write_memberships on memberships
  for all using (current_workspace_role(workspace_id) in ('owner','admin','manager'))
  with check (current_workspace_role(workspace_id) in ('owner','admin','manager'));

drop policy if exists member_read_rooms on rooms;
create policy member_read_rooms on rooms for select using (can_read_workspace(workspace_id));
drop policy if exists manager_write_rooms on rooms;
create policy manager_write_rooms on rooms for all using (can_manage_workspace(workspace_id)) with check (can_manage_workspace(workspace_id));

drop policy if exists member_read_file_assets on file_assets;
create policy member_read_file_assets on file_assets for select using (can_read_workspace(workspace_id));
drop policy if exists producer_write_file_assets on file_assets;
create policy producer_write_file_assets on file_assets for all
  using (current_workspace_role(workspace_id) in ('owner','admin','manager','producer','engineer'))
  with check (current_workspace_role(workspace_id) in ('owner','admin','manager','producer','engineer'));

drop policy if exists member_read_songs on songs;
create policy member_read_songs on songs for select using (deleted_at is null and can_read_workspace(workspace_id));
drop policy if exists producer_write_songs on songs;
create policy producer_write_songs on songs for all
  using (current_workspace_role(workspace_id) in ('owner','admin','manager','producer','engineer','artist'))
  with check (current_workspace_role(workspace_id) in ('owner','admin','manager','producer','engineer','artist'));

drop policy if exists member_read_versions on versions;
create policy member_read_versions on versions for select using (
  exists (
    select 1 from songs
    where songs.song_id = versions.song_id
      and can_read_workspace(songs.workspace_id)
      and songs.deleted_at is null
  )
);
drop policy if exists producer_write_versions on versions;
create policy producer_write_versions on versions for all using (
  exists (
    select 1 from songs
    where songs.song_id = versions.song_id
      and current_workspace_role(songs.workspace_id) in ('owner','admin','manager','producer','engineer')
  )
) with check (
  exists (
    select 1 from songs
    where songs.song_id = versions.song_id
      and current_workspace_role(songs.workspace_id) in ('owner','admin','manager','producer','engineer')
  )
);

drop policy if exists member_read_notes on notes;
create policy member_read_notes on notes for select using (
  exists (
    select 1 from songs
    where songs.song_id = notes.song_id
      and can_read_workspace(songs.workspace_id)
      and (notes.visibility <> 'private' or notes.author_user_id = auth.uid())
  )
);
drop policy if exists member_write_notes on notes;
create policy member_write_notes on notes for all using (
  exists (
    select 1 from songs
    where songs.song_id = notes.song_id
      and current_workspace_role(songs.workspace_id) in ('owner','admin','manager','producer','engineer','artist','anr','viewer')
  )
) with check (
  exists (
    select 1 from songs
    where songs.song_id = notes.song_id
      and current_workspace_role(songs.workspace_id) in ('owner','admin','manager','producer','engineer','artist','anr','viewer')
  )
);

drop policy if exists member_read_tasks on tasks;
create policy member_read_tasks on tasks for select using (can_read_workspace(workspace_id));
drop policy if exists member_write_tasks on tasks;
create policy member_write_tasks on tasks for all using (can_manage_workspace(workspace_id)) with check (can_manage_workspace(workspace_id));

drop policy if exists member_read_links on share_links;
create policy member_read_links on share_links for select using (can_read_workspace(workspace_id));
drop policy if exists manager_write_links on share_links;
create policy manager_write_links on share_links for all
  using (current_workspace_role(workspace_id) in ('owner','admin','manager','producer','engineer'))
  with check (current_workspace_role(workspace_id) in ('owner','admin','manager','producer','engineer'));

drop policy if exists member_read_activity on activity_events;
create policy member_read_activity on activity_events for select using (can_read_workspace(workspace_id));
drop policy if exists service_insert_activity on activity_events;
create policy service_insert_activity on activity_events for insert with check (true);

drop policy if exists self_read_notifications on notifications;
create policy self_read_notifications on notifications for select using (user_id = auth.uid());

drop policy if exists member_read_saved_views on saved_views;
create policy member_read_saved_views on saved_views for select using (can_read_workspace(workspace_id) and (user_id is null or user_id = auth.uid()));

create index if not exists idx_versions_song_current on versions(song_id, is_current);
create index if not exists idx_notes_song_anchor on notes(song_id, anchor_version_id);
create index if not exists idx_activity_song_version on activity_events(song_id, version_id, created_at desc);
create index if not exists idx_share_links_token_hash on share_links(token_hash);
