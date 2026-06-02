-- 0004 — Fix share_links.target_type constraint to include 'playlist'.
--
-- Background: the original migration (0001) restricted share_links.target_type
-- to ('song','room'). However packages/shared/src/models.ts and the in-memory
-- store have always supported a 'playlist' value, and playlist share links
-- are minted by both the web and iOS clients. Against the live Supabase
-- database, those inserts have been silently failing the check constraint.
-- This migration aligns the DB with the application contract.

alter table share_links drop constraint if exists share_links_target_type_check;
alter table share_links
  add constraint share_links_target_type_check
  check (target_type in ('song','room','playlist'));
