# PLAYBACK — Build Handoff

*Session of 2026.05.25 · Claude · companion to the build_plan, design_review, and wireframes_v2 documents*

---

## ★ Supabase is wired and tested end-to-end

The web API now talks to a real Supabase project (Playback, currently project id `pojhfkamzteleogxxfqj`, region us-west-1, on your Pro plan at $10/mo). Verified flow in this session: API boots → hydrates 4 songs / 12 versions / 3 seeded notes / 1 share link from Supabase → recipient POSTs a note via `/notes` → restart the API → note still there. The wedge persists.

**Setup files:**
- `supabase/migrations/0001_private_music_workspace.sql` — applied
- `supabase/migrations/0002_add_external_id_columns.sql` — applied (adds `external_id text unique` to songs/rooms/versions/file_assets/notes/share_links/users so the app's existing string IDs like `song-midnight` keep resolving alongside Supabase UUIDs)
- `supabase/migrations/0003_demo_phase_open_read.sql` — applied (relaxed RLS so the anon publishable key has read+insert on the demo tables; **tighten when real auth lands**)
- `apps/api/src/supabase.ts` — client factory; gated on `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` env vars
- `apps/api/src/supabase-loader.ts` — pulls all tables, shapes to `WorkspaceSnapshot`, substitutes `external_id` for `*_id` fields so existing code is unchanged
- `apps/api/src/supabase-persist.ts` — write-through for notes (insert / resolve / reopen)
- `apps/api/src/store.ts` — added `hydrate()` method called at server boot; `createNote` and `patchNote` fire-and-forget persistence to Supabase

**Env vars to set (local + Render):**
```sh
SUPABASE_URL=https://pojhfkamzteleogxxfqj.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<grab from https://supabase.com/dashboard/project/pojhfkamzteleogxxfqj/settings/api>
```
Without these env vars the API silently falls back to the in-memory seed snapshot (offline dev). With them, it talks to the real DB. The current code uses whatever's in `SUPABASE_SERVICE_ROLE_KEY` — for the wedge demo I'm using the publishable anon key + the relaxed RLS policies. Drop the real service-role key in when you have it and the same code works with stricter policies.

---

## What's shipped this session

### Design system: replaced (highest-leverage change from the review)

The whole frontend now wears the editorial brand from wireframes v2 instead of generic dark-mode SaaS. Specifically:

- **`apps/web/src/styles.css`** — fully rewritten. ~1000 lines. Defines studio mode (workspace, dark), sleeve mode (recipient, cream), brand primitives (`.wordmark`, `.mono-mark`, `.stamp`, `.cat`, `.kicker`), the `.song-card-hero` composition, the `.sticky-composer`, the `.recipient-layout`. All old class names preserved with new brand styling so untouched components keep working.

- **`apps/web/src/App.tsx`** — two surgical refactors, ~200 lines changed:
  - `<SongWorkspace>` now renders the **Song Card hero composition** from the wireframes v2 review (cover-left/metadata-right/waveband-underneath/stamp-overlapping), keeping the VersionStack/NotesPanel/DeliverablesPanel columns below intact.
  - `<SharedListeningPage>` was split into a thin wrapper + new `<SharedListeningView>` that lays out the recipient flow as `recipient-layout` (listening pane + notes column + **persistent sticky composer**). Recipients can leave timestamped notes without auth — the composer pins to the current playhead position.
  - Added brand primitives: `<Wordmark>`, `<MonoMark>`, `<Stamp>` at the end of the file.

- **`apps/web/src/player.tsx`** — replaced the no-op AudioContext placeholder with real HTMLAudioElement playback that uses `asset.playback_url`. Tracks position via rAF, syncs with native `play`/`pause`/`ended` events, falls back to virtual playback when an asset has no URL.

- **`packages/shared/src/models.ts`** — added `playback_url?: string` to `FileAsset`.

- **`packages/shared/src/seed.ts`** — retitled the four placeholder songs to use real demo material:
  - `song-midnight` → **The First Night** by Hudson Ingram (Prod. PomPom)
  - `song-neon` → **Lighting The Fuse** by Hudson Ingram (Co-write Liz Rose)
  - `song-witness` → **Duel** by Ruby Plume
  - `song-lowlight` → **Best Of Me** by Daniel Price · Olmo · Mills
  
  All 12 version assets now have `playback_url` pointing to real audio in `/seed-audio/`.

### Assets

- **`apps/web/public/seed-audio/`** — 8 demo MP3/M4A files (~32 MB total) from `Playback demo archive`, renamed with clean slugs.
- **`apps/web/public/brand/`** — 9 brand-pack PNGs (wordmark, wordmark_reversed, monogram, monogram_reversed, stamp_private/approved/notes_due/latest, app_icon).

### Deploy

- **`render.yaml`** — Render blueprint with two services (`playback-api` Node web service, `playback-web` static SPA). Routes `/shared/*` and `/*` to `index.html` for SPA. Caches `/seed-audio/*` and `/brand/*` aggressively.
- API now uses `tsx src/server.ts` as the start command — bypasses ESM bare-import resolution issues at the cost of ~12 MB runtime overhead. Fine for design-partner phase.

### Verification

- ✅ `npm --workspace @pmw/shared run build` — passes (TypeScript only, no errors)
- ✅ `npm --workspace @pmw/web run build` — passes (1592 modules, 183 KB JS, 28.65 KB CSS, all type-checked)
- ✅ `npm --workspace @pmw/api run build` — passes
- ✅ Live render screenshots from the v3 built-app review confirmed the Song Card hero composition matches wireframes v2

---

## What's still pending (next session)

### High priority

1. **Supabase wiring.** The API is still in-memory (`apps/api/src/store.ts`). Your `music-hub-platform` Supabase project hit the 2-project free-tier limit, so we couldn't restore one of the inactive projects. Options for next session:
    - Pay $25/mo to upgrade and create a dedicated Playback project (cleanest).
    - Delete one of the inactive projects (`bbcalendar` or `theobattaglia1's Project`) to free a slot.
    - Use a Postgres schema in `music-hub-platform` itself (requires light app changes to qualify table names).

   Once a project exists, apply `supabase/migrations/0001_private_music_workspace.sql` (already on disk, 453 lines, RLS-aware), then replace `WorkspaceStore` in `apps/api/src/store.ts` with a Supabase-backed equivalent that conforms to the same interface.

2. **Real auth.** Currently the API trusts the `x-user-id` header (`usr-theo` hardcoded in `apps/web/src/api.ts`). Wire Supabase Auth and forward the JWT.

3. **Real file uploads.** Right now the `addDemoVersion` action fabricates a fake asset. Plug in a `<UploadDropzone>` that hits Supabase Storage via signed URLs, runs `music-metadata` client-side for duration/sample-rate, then POSTs a version with the real `playback_url`.

4. **Mobile screens at 380px.** The CSS has the breakpoints right but I didn't refactor the Song Card hero into a true mobile composition yet (it does scale down, but at 380px the cover image needs to stack above the metadata). Sprint 5 on the build plan.

### Medium

5. **Stamps as PNGs** — the brand `<Stamp>` component currently approximates the typewriter stamps in CSS. The real PNGs are in `apps/web/public/brand/`. For pixel parity, swap the CSS stamps for `<img>` references.

6. **Forever URL surface** — `<LinkManager>` exists but doesn't yet use the brand-pack card composition with QR. The CSS for `.forever-card` is in `styles.css` (from wireframes v2) but no React component consumes it.

7. **Find Similar dossier** — same as Forever URL: no React surface exists yet, but the design pattern is in `wireframes_v2_claude.html` for reference.

### Deferred (per build plan)

8. iMessage extension (native Swift, separate project)
9. Email Receipts via Resend
10. Stem splitting, lyric transcription (compute-cost gated)
11. Billing via Stripe
12. Teams + roles

---

## How to run locally

```sh
cd private-music-workspace
npm install
npm run dev
```

API: `http://localhost:4317`  
Web: `http://localhost:5179`

Then open `http://localhost:5179` for the producer workspace, or `http://localhost:5179/shared/<token>` for the recipient view (any of the seed link tokens — fetch from `/links` endpoint).

---

## How to deploy to Render

1. Push this folder to a GitHub repo.
2. Go to https://dashboard.render.com/blueprints
3. Click "New Blueprint" → connect the repo → Render auto-detects `render.yaml`.
4. Create the two services (`playback-api`, `playback-web`).
5. After first deploy, copy the API URL from Render dashboard and update the `VITE_API_URL` env var on `playback-web` to that URL, then redeploy the web service.
6. Once Supabase is wired (next session), set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` on `playback-api`.

Cost: both services on Render free tier; sufficient for design-partner phase. Upgrade when you hit traffic limits.

---

## Sandbox build notes

The iCloud sync on `~/Library/Mobile Documents/com~apple~CloudDocs/` occasionally locks files mid-write, which broke `npm install` runs against the source folder. To work around this in this session I copied the project to `/tmp/pmw` and built there. If you see the same `EJSONPARSE` or `Resource deadlock avoided` errors when building locally, either:
- Wait a few seconds for iCloud to settle and retry, or
- Build from a non-iCloud directory.

The source-of-truth source files all live in the iCloud folder; `/tmp/pmw` was used only as a build sandbox.

---

## What a design partner sees today

Local-dev producer flow (working):
- Sign-in is auto-set to `usr-theo` (no real auth yet)
- Opens to a Room → Song view showing **The First Night · v2** as the Song Card hero
- Click Play → real audio plays from `/seed-audio/the-first-night-v2.mp3`
- Click the version pills → switches between v1/v2/v3 with real audio
- Click "Add note" → composer opens; submit posts to in-memory store, appears in NotesPanel
- Click "Upload revision" → fabricates a v4 (placeholder until real upload is wired)
- Open `/shared/<token>` (need token from `/links` endpoint) → recipient sleeve-mode view with sticky composer

What's *not* yet demoable:
- Persistence across server restarts (in-memory store)
- Recipient sign-up / inbox (needs auth)
- Find Similar, Forever URL card, iMessage Receipts (UI components not yet built — only designs)
- Mobile-specific layouts (the design system is responsive but the wireframes v2 mobile-specific compositions aren't ported yet)

---

*End of handoff. Companion docs: Playback build plan, design review, and wireframes v2 notes.*
