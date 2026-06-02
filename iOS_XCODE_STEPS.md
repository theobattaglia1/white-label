# Xcode integration — exact steps

*Companion to `iOS_HANDOFF.md`. ~30 min of work, all in Xcode 16+. Each
step has a concrete acceptance check ("Build succeeds", "X appears in
sidebar", etc.).*

You only need to do this once. After it's done, the iOS app + iMessage
extension are wired to the same Supabase that the web app uses.

---

## Prereqs

- macOS, Xcode 16.0 or later
- Apple Developer account ($99/yr) only if you want to run on a real
  iPhone or ship to TestFlight. Simulator works with the free profile.
- The web API live at `https://white-label-api-6mnt.onrender.com` (or
  point to localhost during dev — see step 6).

---

## 1. Open the project

```sh
cd "/Users/theobattaglia/Library/Mobile Documents/com~apple~CloudDocs/1. Personal/Web & App Development 2/private-music-workspace"
open apps/ios/PrivateMusicWorkspace/PrivateMusicWorkspace.xcodeproj
```

**Check:** Xcode opens. You see "PrivateMusicWorkspace" in the sidebar.

---

## 2. Add the new Swift files to the main app target

The session added these files alongside the existing ones, but they
aren't in the Xcode project's file membership yet:

- `Sources/PrivateMusicWorkspace/PMWConfig.swift`
- `Sources/PrivateMusicWorkspace/PMWAPIClient.swift`
- `Sources/PrivateMusicWorkspace/PMWSongCardHero.swift`
- `Sources/PrivateMusicWorkspace/PMWRecipientView.swift`

For each:

1. In Xcode's left sidebar, right-click the `Sources/PrivateMusicWorkspace`
   group → **Add Files to "PrivateMusicWorkspace"…**
2. Navigate to and select the file.
3. In the dialog: **Target Membership = PrivateMusicWorkspace only**.
   Leave "Copy items if needed" UNchecked (the file's already in the
   correct location).
4. Click Add.

Repeat for all four. Then **Cmd+B** to build.

**Check:** Build succeeds (you may see warnings about unused PMWConfig
properties — fine). If you see "Cannot find PMWWordmark in scope" etc,
make sure `PMWTheme.swift` is still in the target (it should be).

---

## 3. Drop `PMWSongCardHero` into the song tab

Open `PMWRootView.swift`. Find the `private var content: some View` block,
or wherever the `.song` tab body is rendered. Replace the existing
song-tab hero region with:

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

Keep the existing `notesPanel`, `versionStackPanel`, `deliverablesPanel`
blocks below it — they still work.

**Check:** Cmd+B builds. Run on Simulator (Cmd+R). The song tab shows
the cover-left/metadata-right hero card.

---

## 4. Wire deep-link recipient view (optional but recommended)

In `PrivateMusicWorkspaceApp.swift` (the `@main` struct), wrap the body
to handle `wl://r/<token>` deep links:

```swift
import SwiftUI

@main
struct PrivateMusicWorkspaceApp: App {
    @State private var recipientToken: String? = nil

    var body: some Scene {
        WindowGroup {
            ZStack {
                PMWRootView()
                if let token = recipientToken {
                    PMWRecipientView(token: token)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeInOut, value: recipientToken)
            .onOpenURL { url in
                guard url.scheme == "wl", url.host == "r" else { return }
                recipientToken = url.lastPathComponent
            }
        }
    }
}
```

Then register the URL scheme:

1. Click the project root in Xcode sidebar → **PrivateMusicWorkspace target**
   → **Info** tab → **URL Types** → click +
2. Identifier: `com.allmyfriends.whitelabel`
3. URL Schemes: `wl`
4. Role: Editor

**Check:** In Simulator, type `xcrun simctl openurl booted wl://r/test_token`
in your terminal. The recipient view appears.

---

## 5. Create the iMessage Extension target

1. **File → New → Target…** → iOS → **iMessage Extension** → Next
2. Product Name: **WhiteLabelReceipts** (must match the folder I created)
3. Team: your Apple ID (or none for Simulator-only)
4. Bundle identifier: `<parent>.WhiteLabelReceipts`
5. Embed in: **PrivateMusicWorkspace** ✓
6. Click Finish.

Xcode creates a default `MessagesViewController.swift` and `MainInterface.storyboard`. **DELETE** the default `MessagesViewController.swift` (the file Xcode just generated — NOT the one I wrote).

Now drag the files from `apps/ios/WhiteLabelReceipts/` into the new
target's group:

- `MessagesViewController.swift`
- `WLReceiptAPI.swift`
- `Info.plist` (replace the auto-generated one — when prompted, choose
  "Replace")

For each file: **Target Membership = WhiteLabelReceipts only**.

**Check:** Cmd+B builds both targets cleanly.

---

## 6. Point the iOS app at the right API

Open `PMWConfig.swift`. The `defaultAPIBaseURL` is currently
`http://127.0.0.1:5180`. For the live demo, change it to:

```swift
static let defaultAPIBaseURL = "https://white-label-api-6mnt.onrender.com"
```

For dev against your local API, you can override via Scheme env var:

1. Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables
2. Add `WL_API_BASE_URL = http://192.168.X.X:4317` (your Mac's LAN IP)

In `WLReceiptAPI.swift`, the iMessage extension's `baseURL` defaults to
`https://white-label-api.onrender.com` — change that constant to
`https://white-label-api-6mnt.onrender.com` too.

**Check:** Run on Simulator. The room view loads with "Hudson Ingram LP
· Approval run" and the 4 songs from your live Supabase.

---

## 7. (Optional) Generate iMessage app icon set

iMessage extensions need a specific multi-size icon catalog. Generate
from `apps/web/public/brand/app_icon.png` (1024×1024):

1. In the WhiteLabelReceipts target, open `Assets.xcassets`
2. Right-click → **New iMessage App Icon**
3. Drag `app_icon.png` into each slot (Xcode will warn if sizes don't
   match — use any online "iMessage icon set generator" with the
   1024×1024 source, or skip and ship without; Apple lets you submit
   later)

---

## 8. Test the iMessage extension end-to-end

The iMessage Extension's "Send Receipt from producer" composer is NOT
built yet (called out in iOS_HANDOFF.md). For now you can test the
RECIPIENT side:

1. Run the parent app on a real iPhone via Xcode (Simulator's iMessage
   support is flaky).
2. Open Messages on the iPhone → tap the App Store icon → swipe to find
   "White Label · Receipts".
3. The compact UI shows. Tap to expand. Approve / send a note → POSTs
   to your live API → check Supabase.

To send a receipt the OTHER direction (producer → recipient), implement
the "compose" view in the main app:

```swift
import Messages
// In any view that has a "Share via iMessage" button:
let message = MSMessage()
message.url = URL(string: "https://white-label-web.onrender.com/shared/<token>")!
let layout = MSMessageTemplateLayout()
layout.image = UIImage(named: "AppIcon")
layout.caption = song.title
layout.subcaption = song.artistName
message.layout = layout
// Then present an MSMessagesAppViewController in a sheet and call:
conversation.insert(message)
```

This is the next iOS sprint; not in scope for this session.

---

## 9. Smoke test checklist

- [ ] App launches in Simulator
- [ ] Song tab shows the Song Card hero composition (cover left,
      metadata right, version pills, waveform band)
- [ ] Stack pills are tappable and switch versions
- [ ] Sample audio actually plays (requires PMWConfig.apiBaseURL
      pointing at a server that serves /seed-audio/*)
- [ ] Notes panel shows seeded notes
- [ ] Recipient view (deep-linked or hard-coded) shows cream-substrate
      design with cover + sticky composer
- [ ] iMessage extension installs alongside the parent app

---

## What's next after this is done

- [ ] Producer-side "compose receipt" view that actually inserts MSMessages
- [ ] Voice memo notes (AVAudioRecorder → upload to Supabase Storage)
- [ ] Real cover art (replace gradient placeholder with AsyncImage)
- [ ] Push notifications for note replies (APNs + Supabase Functions)
- [ ] TestFlight build for design partners

The web app is the wedge; iOS is the polish layer that makes producers
feel at home. Both share the same Supabase, so notes posted from one
appear in the other instantly.
