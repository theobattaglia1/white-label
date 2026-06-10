-- 0015_first_listen_listening_rooms.sql
-- =========================================================================
-- First Listen + Listening Room primitives.
--
-- PLAYBACK's existing rooms table is project/release context. The new
-- listening_rooms table is the private synchronized event surface.
-- External recipients do not get direct table policies; token resolution and
-- audio signing stay behind the API/service-role layer.
-- =========================================================================

do $$ begin
  create type decision_request_type as enum (
    'general_reaction',
    'single_candidate',
    'meeting_interest',
    'forward_interest',
    'sync_fit',
    'mix_note',
    'version_comparison'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type decision_response_value as enum (
    'love',
    'hold',
    'pass',
    'need_context',
    'needs_revision',
    'would_forward'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type share_session_type as enum ('first_listen','standard','room_invite');
exception when duplicate_object then null; end $$;

do $$ begin
  create type share_access_state as enum (
    'unused',
    'opened',
    'started',
    'completed',
    'expired',
    'replay_requested',
    'replay_granted',
    'revoked'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type listening_room_type as enum (
    'first_listen_room',
    'revision_room',
    'single_room',
    'mix_notes_room'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type listening_room_lifecycle_state as enum (
    'draft',
    'scheduled',
    'live',
    'ended',
    'archived',
    'expired',
    'canceled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type listening_room_retention_policy as enum (
    'disappear_after_room',
    'visible_24h',
    'save_to_project'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type listening_room_playback_state as enum ('lobby','playing','paused','ended');
exception when duplicate_object then null; end $$;

do $$ begin
  create type listening_report_type as enum ('first_listen','listening_room');
exception when duplicate_object then null; end $$;

do $$ begin
  create type listening_report_visibility as enum ('private','visible_24h','project');
exception when duplicate_object then null; end $$;

create table if not exists share_sessions (
  share_session_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  artist_id uuid,
  artist_name text,
  song_id uuid not null references songs(song_id) on delete cascade,
  room_id uuid references rooms(room_id) on delete set null,
  version_id uuid references versions(version_id) on delete set null,
  sender_user_id uuid references users(user_id),
  share_type share_session_type not null default 'first_listen',
  decision_request_type decision_request_type not null default 'general_reaction',
  context_note text,
  voice_preface_storage_path text,
  token_hash text not null unique,
  expires_at timestamptz,
  max_first_listens integer not null default 1,
  replay_grants_count integer not null default 0,
  status share_access_state not null default 'unused',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists share_session_recipients (
  recipient_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  share_session_id uuid not null references share_sessions(share_session_id) on delete cascade,
  recipient_user_id uuid references users(user_id),
  recipient_email text,
  recipient_phone text,
  display_name text,
  access_state share_access_state not null default 'unused',
  opened_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  expired_at timestamptz,
  replay_requested_at timestamptz,
  replay_granted_at timestamptz,
  last_position_ms integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists listening_rooms (
  listening_room_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  host_user_id uuid references users(user_id),
  artist_id uuid,
  artist_name text,
  room_id uuid references rooms(room_id) on delete set null,
  room_type listening_room_type not null default 'first_listen_room',
  title text not null,
  context_note text,
  decision_request_type decision_request_type,
  scheduled_start_at timestamptz,
  started_at timestamptz,
  ended_at timestamptz,
  lifecycle_state listening_room_lifecycle_state not null default 'draft',
  retention_policy listening_room_retention_policy not null default 'save_to_project',
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists listening_room_tracks (
  listening_room_track_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  listening_room_id uuid not null references listening_rooms(listening_room_id) on delete cascade,
  song_id uuid not null references songs(song_id) on delete cascade,
  version_id uuid references versions(version_id) on delete set null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists listening_room_participants (
  participant_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  listening_room_id uuid not null references listening_rooms(listening_room_id) on delete cascade,
  user_id uuid references users(user_id),
  recipient_email text,
  recipient_phone text,
  display_name text,
  role_in_room text not null default 'listener' check (role_in_room in ('host','listener')),
  joined_at timestamptz,
  left_at timestamptz,
  completed_at timestamptz,
  first_take_submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists listening_room_state (
  listening_room_id uuid primary key references listening_rooms(listening_room_id) on delete cascade,
  current_track_id uuid references songs(song_id) on delete set null,
  current_version_id uuid references versions(version_id) on delete set null,
  playback_state listening_room_playback_state not null default 'lobby',
  host_position_ms integer not null default 0,
  host_started_at_server_time timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists listening_events (
  listening_event_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  share_session_id uuid references share_sessions(share_session_id) on delete cascade,
  listening_room_id uuid references listening_rooms(listening_room_id) on delete cascade,
  recipient_id uuid references share_session_recipients(recipient_id) on delete set null,
  participant_id uuid references listening_room_participants(participant_id) on delete set null,
  song_id uuid not null references songs(song_id) on delete cascade,
  version_id uuid references versions(version_id) on delete set null,
  event_type text not null,
  playback_position_ms integer,
  percent_complete numeric(5,2),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  check (share_session_id is not null or listening_room_id is not null)
);

create table if not exists decision_responses (
  decision_response_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  share_session_id uuid references share_sessions(share_session_id) on delete cascade,
  listening_room_id uuid references listening_rooms(listening_room_id) on delete cascade,
  recipient_id uuid references share_session_recipients(recipient_id) on delete set null,
  participant_id uuid references listening_room_participants(participant_id) on delete set null,
  song_id uuid not null references songs(song_id) on delete cascade,
  version_id uuid references versions(version_id) on delete set null,
  decision_request_type decision_request_type not null,
  response_value decision_response_value not null,
  confidence integer,
  text_note text,
  voice_note_storage_path text,
  transcript text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (share_session_id is not null or listening_room_id is not null)
);

create table if not exists timestamped_reactions (
  timestamped_reaction_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  share_session_id uuid references share_sessions(share_session_id) on delete cascade,
  listening_room_id uuid references listening_rooms(listening_room_id) on delete cascade,
  recipient_id uuid references share_session_recipients(recipient_id) on delete set null,
  participant_id uuid references listening_room_participants(participant_id) on delete set null,
  song_id uuid not null references songs(song_id) on delete cascade,
  version_id uuid references versions(version_id) on delete set null,
  playback_position_ms integer not null,
  reaction_type text not null check (reaction_type in ('pulse','marker','emoji','run_it_back','voice_note','text_note')),
  intensity integer,
  note_text text,
  voice_note_storage_path text,
  transcript text,
  created_at timestamptz not null default now(),
  check (share_session_id is not null or listening_room_id is not null)
);

create table if not exists listening_reports (
  listening_report_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  report_type listening_report_type not null,
  share_session_id uuid references share_sessions(share_session_id) on delete cascade,
  listening_room_id uuid references listening_rooms(listening_room_id) on delete cascade,
  workspace_id uuid not null references workspaces(workspace_id) on delete cascade,
  artist_id uuid,
  artist_name text,
  song_id uuid references songs(song_id) on delete set null,
  room_id uuid references rooms(room_id) on delete set null,
  version_id uuid references versions(version_id) on delete set null,
  summary_json jsonb not null default '{}',
  created_by uuid references users(user_id),
  visibility listening_report_visibility not null default 'private',
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table share_sessions enable row level security;
alter table share_session_recipients enable row level security;
alter table listening_events enable row level security;
alter table decision_responses enable row level security;
alter table timestamped_reactions enable row level security;
alter table listening_rooms enable row level security;
alter table listening_room_tracks enable row level security;
alter table listening_room_participants enable row level security;
alter table listening_room_state enable row level security;
alter table listening_reports enable row level security;

drop policy if exists member_read_share_sessions on share_sessions;
create policy member_read_share_sessions on share_sessions
  for select using (can_read_workspace(workspace_id));
drop policy if exists manager_write_share_sessions on share_sessions;
create policy manager_write_share_sessions on share_sessions
  for all using (can_manage_workspace(workspace_id))
  with check (can_manage_workspace(workspace_id));

drop policy if exists member_read_share_session_recipients on share_session_recipients;
create policy member_read_share_session_recipients on share_session_recipients for select using (
  exists (
    select 1 from share_sessions s
    where s.share_session_id = share_session_recipients.share_session_id
      and can_read_workspace(s.workspace_id)
  )
);
drop policy if exists manager_write_share_session_recipients on share_session_recipients;
create policy manager_write_share_session_recipients on share_session_recipients for all using (
  exists (
    select 1 from share_sessions s
    where s.share_session_id = share_session_recipients.share_session_id
      and can_manage_workspace(s.workspace_id)
  )
) with check (
  exists (
    select 1 from share_sessions s
    where s.share_session_id = share_session_recipients.share_session_id
      and can_manage_workspace(s.workspace_id)
  )
);

drop policy if exists member_read_listening_rooms on listening_rooms;
create policy member_read_listening_rooms on listening_rooms
  for select using (can_read_workspace(workspace_id));
drop policy if exists manager_write_listening_rooms on listening_rooms;
create policy manager_write_listening_rooms on listening_rooms
  for all using (can_manage_workspace(workspace_id))
  with check (can_manage_workspace(workspace_id));

drop policy if exists member_read_listening_room_tracks on listening_room_tracks;
create policy member_read_listening_room_tracks on listening_room_tracks for select using (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_tracks.listening_room_id
      and can_read_workspace(r.workspace_id)
  )
);
drop policy if exists manager_write_listening_room_tracks on listening_room_tracks;
create policy manager_write_listening_room_tracks on listening_room_tracks for all using (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_tracks.listening_room_id
      and can_manage_workspace(r.workspace_id)
  )
) with check (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_tracks.listening_room_id
      and can_manage_workspace(r.workspace_id)
  )
);

drop policy if exists member_read_listening_room_participants on listening_room_participants;
create policy member_read_listening_room_participants on listening_room_participants for select using (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_participants.listening_room_id
      and can_read_workspace(r.workspace_id)
  )
);
drop policy if exists manager_write_listening_room_participants on listening_room_participants;
create policy manager_write_listening_room_participants on listening_room_participants for all using (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_participants.listening_room_id
      and can_manage_workspace(r.workspace_id)
  )
) with check (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_participants.listening_room_id
      and can_manage_workspace(r.workspace_id)
  )
);

drop policy if exists member_read_listening_room_state on listening_room_state;
create policy member_read_listening_room_state on listening_room_state for select using (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_state.listening_room_id
      and can_read_workspace(r.workspace_id)
  )
);
drop policy if exists manager_write_listening_room_state on listening_room_state;
create policy manager_write_listening_room_state on listening_room_state for all using (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_state.listening_room_id
      and can_manage_workspace(r.workspace_id)
  )
) with check (
  exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_room_state.listening_room_id
      and can_manage_workspace(r.workspace_id)
  )
);

drop policy if exists member_read_listening_events on listening_events;
create policy member_read_listening_events on listening_events for select using (
  exists (
    select 1 from share_sessions s
    where s.share_session_id = listening_events.share_session_id
      and can_read_workspace(s.workspace_id)
  )
  or exists (
    select 1 from listening_rooms r
    where r.listening_room_id = listening_events.listening_room_id
      and can_read_workspace(r.workspace_id)
  )
);
drop policy if exists service_insert_listening_events on listening_events;
create policy service_insert_listening_events on listening_events for insert with check (true);

drop policy if exists member_read_decision_responses on decision_responses;
create policy member_read_decision_responses on decision_responses for select using (
  exists (
    select 1 from share_sessions s
    where s.share_session_id = decision_responses.share_session_id
      and can_read_workspace(s.workspace_id)
  )
  or exists (
    select 1 from listening_rooms r
    where r.listening_room_id = decision_responses.listening_room_id
      and can_read_workspace(r.workspace_id)
  )
);
drop policy if exists service_insert_decision_responses on decision_responses;
create policy service_insert_decision_responses on decision_responses for insert with check (true);

drop policy if exists member_read_timestamped_reactions on timestamped_reactions;
create policy member_read_timestamped_reactions on timestamped_reactions for select using (
  exists (
    select 1 from share_sessions s
    where s.share_session_id = timestamped_reactions.share_session_id
      and can_read_workspace(s.workspace_id)
  )
  or exists (
    select 1 from listening_rooms r
    where r.listening_room_id = timestamped_reactions.listening_room_id
      and can_read_workspace(r.workspace_id)
  )
);
drop policy if exists service_insert_timestamped_reactions on timestamped_reactions;
create policy service_insert_timestamped_reactions on timestamped_reactions for insert with check (true);

drop policy if exists member_read_listening_reports on listening_reports;
create policy member_read_listening_reports on listening_reports for select using (
  can_read_workspace(workspace_id)
  and (expires_at is null or expires_at > now())
  and visibility in ('private','visible_24h','project')
);
drop policy if exists manager_write_listening_reports on listening_reports;
create policy manager_write_listening_reports on listening_reports for all
  using (can_manage_workspace(workspace_id))
  with check (can_manage_workspace(workspace_id));

create index if not exists idx_share_sessions_token_hash on share_sessions(token_hash);
create index if not exists idx_share_sessions_song on share_sessions(song_id, created_at desc);
create index if not exists idx_share_session_recipients_session on share_session_recipients(share_session_id);
create index if not exists idx_listening_events_share on listening_events(share_session_id, created_at desc);
create index if not exists idx_listening_events_room on listening_events(listening_room_id, created_at desc);
create index if not exists idx_decision_responses_share on decision_responses(share_session_id, created_at desc);
create index if not exists idx_decision_responses_room on decision_responses(listening_room_id, created_at desc);
create index if not exists idx_timestamped_reactions_share on timestamped_reactions(share_session_id, playback_position_ms);
create index if not exists idx_timestamped_reactions_room on timestamped_reactions(listening_room_id, playback_position_ms);
create index if not exists idx_listening_rooms_token_hash on listening_rooms(token_hash);
create index if not exists idx_listening_room_tracks_room on listening_room_tracks(listening_room_id, sort_order);
create index if not exists idx_listening_reports_share on listening_reports(share_session_id);
create index if not exists idx_listening_reports_room on listening_reports(listening_room_id);
