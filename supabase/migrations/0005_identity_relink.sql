-- 0005_identity_relink.sql
-- =========================================================================
-- Fix the Supabase-Auth → app-identity mapping so a real sign-in resolves to
-- the PRE-PROVISIONED user row (external_id='usr-theo', etc.) instead of
-- minting a memberless orphan.
--
-- ROOT CAUSE (verified live, see runbook): handle_new_auth_user() INSERTed a
-- fresh row with external_id='auth-<uuid>' on every sign-in. The pre-provisioned
-- rows (usr-theo … usr-river) key all memberships/songs/notes by their
-- app-generated user_id — a UUID that is NOT the Supabase auth UID. So a
-- signed-in user matched no membership, current_workspace_role() returned NULL,
-- and RLS denied everything.
--
-- SAFE SHAPE (per devils-advocate): do NOT move users.user_id. It is the PK
-- with 16 FK children and NONE declare ON UPDATE CASCADE — relinking via the PK
-- would corrupt membership chains. Instead bridge with a new auth_uid column and
-- resolve identity through it everywhere.
--
-- Apply AFTER 0004. After applying: the user signs in once (creating their
-- auth.users row, which fires the relink), then verify, then wire the API env +
-- (optionally) flip REQUIRE_JWT_AUTH. See the runbook handoff for the sequence.
-- =========================================================================

-- 1. Bridge column: the real Supabase auth UID for a provisioned user.
alter table users add column if not exists auth_uid uuid;
create unique index if not exists users_auth_uid_key
  on users(auth_uid) where auth_uid is not null;

-- 2. current_user_id(): map the JWT's auth.uid() → our app user_id (the PK the
--    rest of the schema references). One point of indirection so policies and
--    helpers stop comparing auth.uid() directly against user_id columns.
create or replace function current_user_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select user_id from users where auth_uid = auth.uid() limit 1
$$;

-- 3. Re-point the membership helpers at current_user_id() (was: auth.uid()).
--    can_manage_workspace() calls current_workspace_role() and needs no edit.
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
    and user_id = current_user_id()
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
      and user_id = current_user_id()
  )
$$;

-- 4. The three policies that compared a user_id column directly to auth.uid()
--    must also resolve through current_user_id() now.
drop policy if exists self_read_notifications on notifications;
create policy self_read_notifications on notifications
  for select using (user_id = current_user_id());

drop policy if exists member_read_saved_views on saved_views;
create policy member_read_saved_views on saved_views
  for select using (
    can_read_workspace(workspace_id)
    and (user_id is null or user_id = current_user_id())
  );

drop policy if exists member_read_notes on notes;
create policy member_read_notes on notes for select using (
  exists (
    select 1 from songs
    where songs.song_id = notes.song_id
      and can_read_workspace(songs.workspace_id)
      and (notes.visibility <> 'private' or notes.author_user_id = current_user_id())
  )
);

-- 5. Relink-by-email on sign-in — gated on a CONFIRMED email, and bound to the
--    table. Replaces the orphan-minting version.
--
--    SECURITY (account-takeover prevention): the relink only runs once
--    NEW.email_confirmed_at is set. An attacker signing up as theo@… cannot
--    claim the usr-theo row without controlling that inbox. The `auth_uid is
--    null or = NEW.id` guard makes the link IMMUTABLE after the first claim, so
--    a later auth identity with the same email can never steal a linked row.
--
--    PRECONDITION: email confirmation MUST be enabled in the Supabase project's
--    Auth settings. If it is disabled, email_confirmed_at is set at signup and
--    this gate is moot (anyone who signs up with a seed email claims it). See
--    the handoff — verify this setting before applying.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  display text;
  matched_user_id uuid;
begin
  -- Do nothing until the email is confirmed. On an unconfirmed INSERT we also
  -- skip the row-insert entirely: a seed email would collide with the UNIQUE
  -- email constraint, and a brand-new user has nothing to act on until confirmed.
  if NEW.email_confirmed_at is null then
    return NEW;
  end if;

  display := coalesce(
    NEW.raw_user_meta_data->>'display_name',
    NEW.raw_user_meta_data->>'full_name',
    split_part(NEW.email, '@', 1)
  );

  -- Prefer an existing pre-provisioned row with the same email (email is citext
  -- ⇒ case-insensitive, uniquely constrained ⇒ at most one match). Relink it to
  -- this auth identity WITHOUT touching its user_id (PK) or external_id, so every
  -- membership / song / note FK keeps pointing at the same identity.
  select user_id into matched_user_id
  from public.users
  where email = NEW.email
  limit 1;

  if matched_user_id is not null then
    update public.users
      set auth_uid      = NEW.id,
          display_name  = coalesce(display_name, display),
          auth_provider = coalesce(NEW.raw_app_meta_data->>'provider', auth_provider, 'email'),
          updated_at    = now()
      where user_id = matched_user_id
        and (auth_uid is null or auth_uid = NEW.id);  -- claim-once / immutable
    -- UPDATE (not INSERT) ⇒ on_user_create_workspace does not fire ⇒ no junk
    -- workspace for a pre-provisioned user.
    return NEW;
  end if;

  -- No pre-provisioned match: a brand-new, confirmed account. Create the user
  -- with auth_uid set; the on_user_create_workspace trigger then gives them their
  -- own workspace + owner membership.
  insert into public.users (user_id, auth_uid, email, display_name, auth_provider, external_id)
  values (
    NEW.id,
    NEW.id,
    NEW.email,
    display,
    coalesce(NEW.raw_app_meta_data->>'provider', 'email'),
    'auth-' || substring(NEW.id::text, 1, 8)
  )
  on conflict (user_id) do update set
    auth_uid     = excluded.auth_uid,
    email        = excluded.email,
    display_name = excluded.display_name;

  return NEW;
end;
$$;

-- Bind the trigger HERE (self-contained — do not rely on a trigger created
-- by hand in the dashboard, which would be missing on any fresh/replayed
-- project and silently reinstate the orphan bug). Fires on INSERT (covers
-- auto-confirm projects) and on the email-confirmation UPDATE.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of email_confirmed_at on auth.users
  for each row execute function public.handle_new_auth_user();

-- NOTE: this migration does not backfill auth_uid for the 5 seed users — they
-- have no auth.users row yet (auth.users count = 0). auth_uid is populated the
-- first time each signs in. Until then they resolve to a memberless identity at
-- the RLS layer (fail-closed), while the API service-role path is unaffected.
