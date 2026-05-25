# Private Music Workspace

A standalone private workspace for unreleased music. It keeps songs as the central product object, stacks every mix/master as a version, and carries timestamped notes forward so old feedback stays useful when the current version changes.

The build is intentionally separate from Music Hub while borrowing the same design language: neutral canvas, red editorial accent, hairline structure, shallow radii, tactile compact controls, and clear hierarchy.

## Apps

- `apps/api` — Fastify + TypeScript REST API with seeded data, version-stack mutations, link-mediated access, analytics, deliverables, and a read-only assistant endpoint.
- `apps/web` — React + TypeScript + Vite client with a persistent mini-player, Song Cards, version stack, carry-forward notes, comparison mode, executive inbox, links, and assistant.
- `apps/ios` — Native SwiftUI iOS app project with the same product model and design language, including offline queue and player/comparison scaffolds.
- `apps/uploader` — Cross-platform folder watcher that uploads new audio files as versions through the shared API.
- `packages/shared` — Shared models, seed data, carry-forward note engine, filename grouping, deliverables, link resolution, and read-only assistant helpers.

## Run locally

```sh
npm install
npm run dev
```

API: `http://localhost:4317`

Web: `http://localhost:5179`

Build all TypeScript surfaces:

```sh
npm run build
```

Build the iOS target:

```sh
npm run ios:build
```

## Production integration boundaries

The local demo uses seeded in-memory data so the product flow can be reviewed immediately. The backend boundaries match the specification: Supabase/Postgres + RLS for tenant isolation, Cloudflare R2 signed object access, tus upload endpoints, background media processing hooks, and read-only assistant behavior. The migration in `supabase/migrations/0001_private_music_workspace.sql` defines the production data model.

