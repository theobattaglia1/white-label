-- The upload bucket stores both audio masters and song artwork. Migration 0011
-- created the bucket as audio-only, which made edit-song artwork uploads fail
-- with `invalid_mime_type` for JPEG/PNG/HEIC selections from Photos.
UPDATE storage.buckets
SET allowed_mime_types = ARRAY[
  'audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/wav',
  'audio/x-wav', 'audio/flac', 'audio/x-flac', 'audio/aiff',
  'audio/x-aiff', 'audio/ogg', 'audio/webm', 'video/mp4',
  'image/jpeg', 'image/jpg', 'image/png', 'image/heic', 'image/heif', 'image/webp'
]
WHERE id = 'wl-audio';
