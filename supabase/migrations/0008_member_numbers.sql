-- Migration 0008: member_number — sequential account identity.
-- Assigned once in creation order, permanent. PB-001 is the first account.

-- Add the column
ALTER TABLE users ADD COLUMN IF NOT EXISTS member_number integer;

-- Sequence for new signups
CREATE SEQUENCE IF NOT EXISTS user_member_seq START 1;

-- Backfill existing users by created_at ascending
WITH ranked AS (
  SELECT user_id,
         ROW_NUMBER() OVER (ORDER BY created_at ASC, user_id ASC) AS rn
  FROM users
)
UPDATE users SET member_number = ranked.rn
FROM ranked WHERE users.user_id = ranked.user_id;

-- Advance sequence past current max so new signups continue cleanly
SELECT setval('user_member_seq',
  COALESCE((SELECT MAX(member_number) FROM users), 0) + 1,
  false);

-- Wire default for new rows
ALTER TABLE users ALTER COLUMN member_number SET DEFAULT nextval('user_member_seq');
ALTER SEQUENCE user_member_seq OWNED BY users.member_number;

-- Index for fast lookup
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_member_number ON users(member_number);
