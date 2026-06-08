-- Specific people invited to a share link. Links can still be public, but this
-- table gives the product a durable recipient/permission surface: resend,
-- change role, revoke one person, and audit who was invited.

create table if not exists share_recipients (
  recipient_id uuid primary key default gen_random_uuid(),
  external_id text unique,
  link_id uuid not null references share_links(link_id) on delete cascade,
  email text not null,
  display_name text,
  role text not null default 'listen' check (role in ('listen','comment','download')),
  invited_by uuid references users(user_id),
  invited_at timestamptz not null default now(),
  last_sent_at timestamptz,
  accepted_at timestamptz,
  revoked_at timestamptz
);

create index if not exists idx_share_recipients_link on share_recipients(link_id);
create index if not exists idx_share_recipients_email on share_recipients(lower(email));

alter table share_recipients enable row level security;

drop policy if exists member_read_share_recipients on share_recipients;
create policy member_read_share_recipients on share_recipients for select using (
  exists (
    select 1
    from share_links l
    where l.link_id = share_recipients.link_id
      and can_read_workspace(l.workspace_id)
  )
);

drop policy if exists manager_write_share_recipients on share_recipients;
create policy manager_write_share_recipients on share_recipients for all
  using (
    exists (
      select 1
      from share_links l
      where l.link_id = share_recipients.link_id
        and current_workspace_role(l.workspace_id) in ('owner','admin','manager','producer','engineer')
    )
  )
  with check (
    exists (
      select 1
      from share_links l
      where l.link_id = share_recipients.link_id
        and current_workspace_role(l.workspace_id) in ('owner','admin','manager','producer','engineer')
    )
  );
