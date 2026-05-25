# WHITE LABEL — iOS Handoff

*Session of 2026.05.25 · Claude · companion to `HANDOFF.md` (web)*

This session covered the iOS app and the iMessage extension. The sandbox here has no Xcode, so every Swift file was written blind and is **unverified at compile time** — you'll need to open the project in Xcode and tighten anything the compiler flags. Where I was uncertain about a SwiftUI shape (deprecated APIs vs new ones, iOS 15 vs 17 minimum, etc.), I biased toward iOS 16+ idioms because the existing project already uses `safeAreaInset` and `presentationDetents`.

---

## What's new in `apps/ios/`

### Files added or rewritten under `PrivateMusicWorkspace/Sources/PrivateMusicWorkspace/`

| File | Status | What it does |
|---|---|---|
| `PMWTheme.swift` | **rewritten** | Editorial brand tokens — studio mode (dark workspace), sleeve mode (cream recipient), redline `#D9281D`, notes-blue `#2D5DB8`, condensed-grotesque display font, typewriter mono. Adds `PMWWordmark`, `PMWMonoMark`, `PMWStamp`, `PMWCatalogId` SwiftUI primitives. Old token names (`canvas`, `paper`, `ink`, `accent`…) preserved and re-pointed so legacy views become brand-true without code changes. `PMWChromeButtonStyle` now has `variant: .ghost / .dark / .accent` plus a back-compat `init(accent: Bool)` so existing call sites keep working. |
| `PMWConfig.swift` | **new** | Runtime config. `apiBaseURL` resolves from env var `WL_API_BASE_URL`, defaults to `http://127.0.0.1:5180`. `useRemoteAPI` toggles between PMWSampleData and PMWAPIClient via `WL_USE_REMOTE_API=1`. `devUserId = "usr-theo"` sent as `x-user-id` header. |
| `PMWAPIClient.swift` | **new** | URLSession client for `/rooms/:id`, `/songs/:id`, `/shared/:token`, `POST /notes`, `POST /versions/:id/approvals`. Decodes the JSON envelope used by the web API. |
| `PMWAudioEngine.swift` | **rewritten** | Real AVPlayer-backed playback. Resolves each `PMWAsset.assetURLPath` against `PMWConfig.apiBaseURL`. Periodic time observer ticks `positionMS` at 50ms. Falls back to virtual mode when an asset has no URL. |
| `PMWModels.swift` | **patched** | Added `assetURLPath: String?` to `PMWAsset`. Added a computed `catalogId` ("WL · 0142") to `PMWSong`. Everything else preserved. |
| `PMWSampleData.swift` | **rewritten** | Real song titles (The First Night by Hudson Ingram, Lighting The Fuse, Duel by Ruby Plume, Best Of Me by Daniel Price) with `assetURLPath` pointing at `seed-audio/…`. The audio files are served by the **web app** (Vite serves `/public`); the iOS app pulls them over HTTP, so the web dev server must be running at `PMWConfig.apiBaseURL` for audio to play. |
| `PMWStore.swift` | **rewritten** | Same `selectSong / setCurrent / addNote / resolve / reopen / deliverables / assistantAnswer` surface as before. Added `loadFromAPIIfEnabled()` — call from `.task { … }` on root view; it hits `PMWAPIClient.shared.room()` when `useRemoteAPI` is on. Notes are optimistically appended locally and posted to the API in the background. |
| `PMWSongCardHero.swift` | **new** | The Song Card hero composition from wireframes v2 (cover top, metadata, version pills, action row, waveform band, three-column below). Self-contained: doesn't touch state, just renders. Drop it into `PMWRootView`'s song tab — wiring example in the file's doc comment. |
| `PMWRecipientView.swift` | **new** | Recipient listening surface (analog of the web's `SharedListeningView`). Sleeve mode. Fetches `/shared/:token` via `PMWAPIClient`. Composer at the bottom posts notes back to the API. Triggered by `wl://r/<token>` deep link or a debug menu. |

### Files added under `apps/ios/WhiteLabelReceipts/` (iMessage extension — new target)

| File | Status | What it does |
|---|---|---|
| `MessagesViewController.swift` | **new** | `MSMessagesAppViewController` subclass. Hosts a SwiftUI receipt view in both compact (~220pt) and expanded (~414pt) presentations. Approve button → POST `/versions/:id/approvals`. Reply note → POST `/notes`. |
| `WLReceiptAPI.swift` | **new** | Tiny URLSession client. Defaults to `https://white-label-api.onrender.com` (your production Render URL); override via `WL_API_BASE_URL`. |
| `Info.plist` | **new** | Extension Info.plist with the iMessage extension point (`com.apple.message-payload-provider`), `MainInterface` storyboard reference, `NSAllowsLocalNetworking` for dev. |

---

## Xcode work you have to do manually

I can't drive Xcode from here, so these steps need you. None are hard — under 30 min total.

### 1. Add the new Swift files to the main app target

In Xcode → `apps/ios/PrivateMusicWorkspace/PrivateMusicWorkspace.xcodeproj` → drag these into the `PrivateMusicWorkspace` group → make sure "Target Membership" includes `PrivateMusicWorkspace`:

- `PMWConfig.swift`
- `PMWAPIClient.swift`
- `PMWSongCardHero.swift`
- `PMWRecipientView.swift`

(`PMWTheme.swift`, `PMWAudioEngine.swift`, `PMWModels.swift`, `PMWSampleData.swift`, `PMWStore.swift` were already in the project and I rewrote them in place.)

### 2. Wire `PMWSongCardHero` into the song tab

Open `PMWRootView.swift`, find the song tab's body — it's the `case .song:` arm of the root tab switch. Replace the existing custom hero block with:

```swift
PMWSongCardHero(
    song: store.selectedSong,
    versions: store.selectedVersions,
    currentVersion: store.currentVersion,
    asset: store.currentAsset,
    notes: store.visibleNotes,
    isPlaying: audio.isPlaying,
    positionMs: audio.positionMS,
    onPlay: {
        if let asset = store.currentAsset {
            audio.play(song: store.selectedSong, version: store.currentVersion, asset: asset)
        }
    },
    onPause: { audio.pause() },
    onSelectVersion: { v in
        store.setCurrent(v)
        if let a = store.asset(for: v) {
            audio.play(song: store.selectedSong, version: v, asset: a)
        }
    },
    onAddNote: { noteComposerPresented = true },
    onUploadRevision: { store.addDemoVersion() }
)
```

Then the existing `notesPanel`, `versionStackPanel`, `deliverablesPanel` blocks below it can stay as-is.

### 3. Hook `PMWRecipientView` to a deep link

Open `PrivateMusicWorkspaceApp.swift` (root `@main` struct) and add:

```swift
.onOpenURL { url in
    guard url.scheme == "wl", url.host == "r" else { return }
    let token = url.lastPathComponent
    // present recipient view — e.g. via a @State path stack or a sheet
    recipientToken = token
}
.sheet(item: $recipientToken) { token in
    NavigationStack { PMWRecipientView(token: token.value) }
}
```

You'll need to declare a `String?`-wrapping `IdentifiableToken` to use with `.sheet(item:)` — or just use a `@State var recipientToken: String? = nil` and a Bool-driven sheet. Then in `Info.plist`, register `wl` as a URL scheme under `CFBundleURLTypes`.

### 4. Create the iMessage extension target

Xcode does this for you via a target template:

1. File → New → Target → iOS → **iMessage Extension**
2. Product name: **WhiteLabelReceipts** (matches the directory I created)
3. Bundle identifier: parent app's bundle id + `.receipts` (Xcode generates this)
4. Language: Swift, Embed in app: PrivateMusicWorkspace
5. Click Finish. Xcode creates a default `MessagesViewController.swift` and storyboard. **Delete them.**
6. Drag the files from `apps/ios/WhiteLabelReceipts/` (`MessagesViewController.swift`, `WLReceiptAPI.swift`, `Info.plist`) into the new target. Make Target Membership = WhiteLabelReceipts only.
7. In the target's Info → Custom iOS Target Properties, set `MSMessagesAppPresentationContextMessages = YES`.
8. Add an iMessage App Icon catalog (Asset Catalog → New iMessage App Icon). 1024x1024 → 67x50 → 27x21. You can derive these from `apps/web/public/brand/app_icon.png`.

### 5. Production base URL

Once your Render API is live, update two strings:

- `PMWConfig.swift` → `defaultAPIBaseURL` → your Render web/static URL (Vite-built bundle serves `/seed-audio` from there too).
- `WLReceiptAPI.swift` → `baseURL` default → your Render API URL.

---

## Running it locally

```sh
# Terminal 1 — start the API + web (audio host) the iOS app talks to
cd private-music-workspace
npm install
npm run dev      # API on :4317, Vite on :5179

# Terminal 2 — open the iOS app in Xcode
open apps/ios/PrivateMusicWorkspace/PrivateMusicWorkspace.xcodeproj
# Run on iOS Simulator. With no env var set, it reads from PMWSampleData
# (offline-friendly, has real song titles + real audio).
# To flip to the live API:
#   In Xcode > Scheme > Run > Arguments > Environment Variables:
#     WL_USE_REMOTE_API = 1
#     WL_API_BASE_URL  = http://127.0.0.1:5180
```

On a real device on the same Wi-Fi as your Mac, replace `127.0.0.1` with the Mac's LAN IP (e.g. `http://192.168.4.18:5180`). Audio streams from there.

---

## Recipient view on device

For a quick test without standing up the deep-link plumbing: temporarily replace the contents of `PrivateMusicWorkspaceApp.swift`'s body with:

```swift
WindowGroup {
    PMWRecipientView(token: "<any token from your /links endpoint>")
}
```

Then run. You'll get the cream-substrate recipient view, the cover gradient, the transport, the composer pinned to the bottom. Real notes get POSTed to your local API.

---

## iMessage extension on device

iMessage extensions only work on physical devices (Simulator's iMessage support is flaky). Steps:

1. Connect an iPhone, set the run target to PrivateMusicWorkspace on that device.
2. Build & run. Both the host app and the extension install.
3. Open Messages on the iPhone → tap the App Store icon in the message bar → swipe to find "White Label".
4. The compact UI shows; tap the cover to expand. Approve / send a note → hits your API.

To **send** a receipt as a producer (from Messages on the same device or a teammate's device), you'll need to add a small composer view to the main app that calls `MSMessagesAppViewController.activeConversation.insert(message)`. I didn't build that surface this session — flagged as next step.

---

## What still needs doing (in rough priority order)

1. **Test the build in Xcode.** I'm sure I've introduced at least one Swift typo. The biggest risk: the `PMWChromeButtonStyle` rewrite changes its initializer, and `PMWRootView` uses the old shape in places. Compile, fix call sites.
2. **Replace `PMWRootView`'s song tab** with the `PMWSongCardHero` call (step 2 above).
3. **Add the deep-link entry** for `PMWRecipientView` (step 3).
4. **Create the iMessage extension target** in Xcode (step 4).
5. **Wire `MSMessagesAppViewController.activeConversation.insert(message)`** in the main app so producers can actually compose receipts to send. Not built this session.
6. **iMessage app icon set.** Generate the 1024 / 67×50 / 27×21 sizes from `apps/web/public/brand/app_icon.png`.
7. **Supabase wiring** (next session, blocked by the 2-project free-tier limit — see `HANDOFF.md`).
8. **Replace `PMWSampleData` cleanly.** Right now the iOS app reads from sample data even when `useRemoteAPI` is on for the *initial* paint, then `loadFromAPIIfEnabled()` overwrites. The flash is brief but a real boot-load spinner would feel better.
9. **Voice-memo notes.** The mic button is a TODO in both `PMWRecipientView` and the iMessage extension. Use `AVAudioRecorder` → upload to API → `notes.voice_storage_path`.
10. **Real cover art.** Currently a procedural gradient. When real cover art exists, store URL on `PMWAsset` and render via `AsyncImage`.

---

## Honest summary of what I shipped vs claimed

**Shipped:**
- Brand-true theme + primitives ✓
- New API client wired into store with optional remote mode ✓
- Real AVPlayer audio playback that resolves URLs against config ✓
- Self-contained Song Card hero component matching wireframes v2 ✓
- Self-contained Recipient view with sticky composer matching wireframes v2 ✓
- iMessage Extension scaffold (controller + API client + Info.plist) ✓
- This handoff document ✓

**Did NOT ship (requires Xcode):**
- Compile verification ✗
- Actual integration of `PMWSongCardHero` into `PMWRootView` ✗
- Actual creation of the iMessage Xcode target ✗
- App icon for the iMessage extension ✗
- The producer-side "Send Receipt" composer that inserts MSMessages ✗

Plan ~1 evening in Xcode to wire those up. None of them are conceptually hard; they're all "do the Xcode dance."

---

*End of iOS handoff. Pair with `HANDOFF.md` for the web side.*
