-- Create the wl-audio storage bucket for real audio uploads.
-- Upsert-safe: ON CONFLICT DO NOTHING, so re-running is harmless.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'wl-audio',
  'wl-audio',
  false,
  524288000,  -- 500 MB per file
  ARRAY[
    'audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/wav',
    'audio/x-wav', 'audio/flac', 'audio/x-flac', 'audio/aiff',
    'audio/x-aiff', 'audio/ogg', 'audio/webm', 'video/mp4'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- Storage RLS policies for wl-audio
-- DROP + CREATE is idempotent on PG15 (IF NOT EXISTS on CREATE POLICY requires PG17+).

-- 1. Service role (API server): full read + write.
DROP POLICY IF EXISTS "wl-audio service role full access" ON storage.objects;
CREATE POLICY "wl-audio service role full access"
  ON storage.objects
  FOR ALL
  TO service_role
  USING (bucket_id = 'wl-audio')
  WITH CHECK (bucket_id = 'wl-audio');

-- 2. Authenticated users: upload.
DROP POLICY IF EXISTS "wl-audio authenticated upload" ON storage.objects;
CREATE POLICY "wl-audio authenticated upload"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'wl-audio');

-- 3. Authenticated users: read.
DROP POLICY IF EXISTS "wl-audio authenticated read" ON storage.objects;
CREATE POLICY "wl-audio authenticated read"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (bucket_id = 'wl-audio');
