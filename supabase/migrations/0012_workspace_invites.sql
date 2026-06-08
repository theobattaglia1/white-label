-- 0012_workspace_invites.sql
-- =========================================================================
-- Invite-only access for beta.
--
-- Design: owner sends an invite (API creates this row + Supabase sends the
-- email). When the recipient confirms their email the existing
-- handle_new_auth_user() trigger fires. We extend it here to consume any
-- pending invite for that email: create the membership and delete the invite
-- row atomically.  No polling, no webhook, no extra API call on first login.
-- =========================================================================

-- Pending invitations --------------------------------------------------
CREATE TABLE IF NOT EXISTS workspace_invites (
  invite_id    uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  workspace_id uuid        NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
  email        citext      NOT NULL,
  role         member_role NOT NULL DEFAULT 'viewer',
  display_name text,
  invited_by   text,   -- external_id of inviting user (no FK; owner may be a seed user)
  invited_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, email)
);

-- RLS: only service-role writes; API handles auth checks upstream
ALTER TABLE workspace_invites ENABLE ROW LEVEL SECURITY;

-- Extend handle_new_auth_user() to auto-provision membership from invite --
-- The entire function is replaced (CREATE OR REPLACE). Logic added at the
-- end: after creating / relinking the user row, check workspace_invites for
-- their confirmed email. If found, INSERT the membership and DELETE the invite.
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  display          text;
  matched_user_id  uuid;
  invite_rec       workspace_invites%ROWTYPE;
BEGIN
  -- Skip unconfirmed rows (same guard as before)
  IF NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  display := COALESCE(
    NEW.raw_user_meta_data->>'display_name',
    NEW.raw_user_meta_data->>'full_name',
    split_part(NEW.email, '@', 1)
  );

  -- Try to match a pre-provisioned user row by email
  SELECT user_id INTO matched_user_id
  FROM public.users
  WHERE email = NEW.email
  LIMIT 1;

  IF matched_user_id IS NOT NULL THEN
    -- Relink existing pre-provisioned row (claim-once: auth_uid immutable after first link)
    UPDATE public.users
      SET auth_uid      = NEW.id,
          display_name  = COALESCE(display_name, display),
          auth_provider = COALESCE(NEW.raw_app_meta_data->>'provider', auth_provider, 'email'),
          updated_at    = now()
      WHERE user_id = matched_user_id
        AND (auth_uid IS NULL OR auth_uid = NEW.id);
  ELSE
    -- Brand-new confirmed user: create row (user_id = Supabase auth UID for simplicity)
    INSERT INTO public.users (user_id, auth_uid, email, display_name, auth_provider, external_id)
    VALUES (
      NEW.id,
      NEW.id,
      NEW.email,
      display,
      COALESCE(NEW.raw_app_meta_data->>'provider', 'email'),
      'auth-' || substring(NEW.id::text, 1, 8)
    )
    ON CONFLICT (user_id) DO UPDATE SET
      auth_uid     = excluded.auth_uid,
      email        = excluded.email,
      display_name = excluded.display_name;

    matched_user_id := NEW.id;
  END IF;

  -- Auto-provision workspace membership from any pending invite for this email
  SELECT * INTO invite_rec
  FROM public.workspace_invites
  WHERE email = NEW.email
  LIMIT 1;

  IF invite_rec.invite_id IS NOT NULL THEN
    -- Upsert membership (idempotent if they somehow already have one)
    INSERT INTO public.memberships (workspace_id, user_id, role)
    VALUES (invite_rec.workspace_id, matched_user_id, invite_rec.role)
    ON CONFLICT (workspace_id, user_id) DO UPDATE SET role = excluded.role;

    -- Consume the invite so it can't be replayed
    DELETE FROM public.workspace_invites WHERE invite_id = invite_rec.invite_id;
  END IF;

  RETURN NEW;
END;
$$;

-- Re-bind the trigger (same events as before; OR REPLACE on the function is
-- enough — the trigger binding itself doesn't need to change).
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT OR UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();
