-- Migration 0009: song artwork metadata + playlist share-link targets.

alter table songs add column if not exists artwork_key text;
alter table songs add column if not exists artwork_url text;

do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conname = 'share_links_target_type_check'
      and conrelid = 'share_links'::regclass
  ) then
    alter table share_links drop constraint share_links_target_type_check;
  end if;
end $$;

alter table share_links
  add constraint share_links_target_type_check
  check (target_type in ('song', 'room', 'playlist'));
