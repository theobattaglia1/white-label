import SwiftUI

/// Recipient listening surface — the iOS analog of the web's
/// `SharedListeningView`. Sleeve mode (cream substrate). Cover at top,
/// title + version pills + transport in the middle, sticky note composer
/// pinned to the safe area bottom.
///
/// Triggered by:
/// - `playback://r/<token>` deep link (handled in PrivateMusicWorkspaceApp's
///   `.onOpenURL`), or
/// - debug menu in producer view ("Open as recipient")
///
/// The implementation here is intentionally self-contained: it fetches
/// its own state via PMWAPIClient.shared.shared(token:) so it doesn't
/// share PMWStore (recipients don't have producer state). Notes posted
/// from this view hit POST /notes directly.
struct PMWRecipientView: View {
    let token: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = PMWAudioEngine()

    @State private var payload: PMWAPIClient.SharedPayload?
    @State private var selectedSongID: String?
    @State private var activeVersionID: String?
    @State private var noteBody: String = ""
    @State private var posting = false
    @State private var notes: [PMWAPIClient.APINote] = []
    @State private var loadError: String?
    @State private var noteError: String?
    @State private var approveState: ApproveState = .idle
    @State private var noteJustPosted = false
    @FocusState private var composerFocused: Bool

    private enum ApproveState { case idle, pending, done }

    var body: some View {
        ZStack {
            PMWColors.sleeveCream.ignoresSafeArea()

            if let payload, let song = currentSong(payload), let current = currentVersion(payload) {
                contentScroll(payload: payload, song: song, current: current)
            } else if let loadError {
                VStack(spacing: 12) {
                    Text("Couldn't open link")
                        .font(PMWFont.display(28, weight: .heavy))
                        .foregroundStyle(PMWColors.inkDeep)
                    Text(loadError)
                        .font(PMWFont.mono(11))
                        .foregroundStyle(PMWColors.pencilCool)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                ProgressView("Opening private link…")
                    .tint(PMWColors.inkDeep)
                    .foregroundStyle(PMWColors.pencilCool)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let noteError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(noteError)
                            .font(PMWFont.mono(11))
                        Spacer()
                        Button("Dismiss") { self.noteError = nil }
                            .font(PMWFont.mono(11, weight: .bold))
                    }
                    .foregroundStyle(PMWColors.redline)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(PMWColors.sleeveElevated)
                }
                composer
            }
        }
        .sensoryFeedback(.success, trigger: noteJustPosted)
        .sensoryFeedback(.success, trigger: approveState == .done)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: token) { await load() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PMWColors.inkDeep)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 2).stroke(PMWColors.sleeveHairline, lineWidth: 1))
            }
            .padding(.top, 8).padding(.trailing, 12)
            .accessibilityLabel("Close private link")
        }
        .overlay(alignment: .top) {
            HStack {
                PMWWordmark(size: .sm)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 14)
        }
    }

    // MARK: - Content -----------------------------------------------

    @ViewBuilder
    private func contentScroll(payload: PMWAPIClient.SharedPayload,
                               song: PMWAPIClient.APISong,
                               current: PMWAPIClient.APIVersion) -> some View {
        let asset = assetFor(current.file_asset_id, in: payload)
        let songNotes = notes
            .filter { $0.song_id == song.song_id }
            .sorted { ($0.timestamp_start_ms ?? .max) < ($1.timestamp_start_ms ?? .max) }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 56) // wordmark + close room
                crumb(payload: payload, song: song, current: current)
                title(song: song, current: current)
                metaRow(asset: asset, song: song)
                cover(song: song)
                transport(asset: asset, song: song, current: current)
                if payload.link.allow_approval == true {
                    approveSection(current: current)
                }
                versions(payload: payload, current: current)
                notesList(songNotes: songNotes)
                if payload.songs.count > 1 { otherSongs(payload: payload) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    private func approveSection(current: PMWAPIClient.APIVersion) -> some View {
        VStack(spacing: 8) {
            switch approveState {
            case .idle where current.is_approved == false:
                Button { Task { await submitApproval(current) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 16, weight: .semibold))
                        Text("APPROVE \(current.version_label?.uppercased() ?? "VERSION")")
                            .font(PMWFont.mono(13, weight: .bold))
                            .kerning(1.4)
                    }
                    .foregroundStyle(PMWColors.sleeveCream)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 2).fill(PMWColors.inkDeep))
                }
                .accessibilityLabel("Approve \(current.version_label ?? "current version")")
            case .pending:
                Text("SENDING APPROVAL…")
                    .font(PMWFont.mono(12, weight: .bold))
                    .kerning(1.6)
                    .foregroundStyle(PMWColors.pencilCool)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            case .done, .idle:
                PMWStamp(text: current.is_approved || approveState == .done ?
                          "Approved · \(current.version_label ?? "")" : "Already approved",
                         kind: .approved, straight: true)
            }
        }
        .padding(.top, 20)
    }

    private func submitApproval(_ v: PMWAPIClient.APIVersion) async {
        approveState = .pending
        do {
            _ = try await PMWAPIClient.shared.approve(token: token, versionID: v.version_id)
            approveState = .done
        } catch {
            approveState = .idle
            noteError = "Approval didn't send: \(error.localizedDescription)"
        }
    }

    private func crumb(payload: PMWAPIClient.SharedPayload,
                       song: PMWAPIClient.APISong,
                       current: PMWAPIClient.APIVersion) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(catalogLabel(songId: song.song_id)) · \(song.title)")
                    .font(PMWFont.mono(11, weight: .bold))
                    .foregroundStyle(PMWColors.inkDeep)
                Text("\(song.artist_display_name ?? "") · sent via private link")
                    .font(PMWFont.mono(10))
                    .foregroundStyle(PMWColors.pencilCool)
            }
            Spacer()
            HStack(spacing: 6) {
                if payload.link.version_policy == "latest_only" {
                    PMWStamp(text: "v\(current.version_number) · Latest", kind: .latest, tight: true, straight: true)
                }
                if current.is_approved {
                    PMWStamp(text: "Approved", kind: .approved, tight: true, straight: true)
                } else {
                    PMWStamp(text: "Notes Welcome", kind: .notesDue, tight: true)
                }
            }
        }
        .padding(.top, 6)
    }

    private func cover(song: PMWAPIClient.APISong) -> some View {
        ZStack(alignment: .bottomLeading) {
            pmwCoverGradient(for: song.song_id)
                .aspectRatio(2.2, contentMode: .fit)
            PMWMonoMark(size: 22, tint: .white)
                .padding(.leading, 14).padding(.bottom, 10)
        }
        .padding(.top, 14)
    }

    private func title(song: PMWAPIClient.APISong, current: PMWAPIClient.APIVersion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title)
                .font(PMWFont.display(40, weight: .heavy))
                .kerning(-1.2)
                .foregroundStyle(PMWColors.inkDeep)
            Text("\(song.artist_display_name ?? "") · \(current.version_label ?? "v\(current.version_number)")")
                .font(PMWFont.sans(16))
                .foregroundStyle(PMWColors.pencilCool)
        }
        .padding(.top, 14)
    }

    private func metaRow(asset: PMWAPIClient.APIAsset?, song: PMWAPIClient.APISong) -> some View {
        HStack(spacing: 14) {
            if let ms = asset?.duration_ms { Text(formatMs(ms)).inkBold() }
            if let bpm = song.bpm { Text("\(bpm) BPM").inkBold() }
            if let key = song.song_key { Text(key).inkBold() }
            if let lufs = asset?.loudness_lufs {
                Text("\(String(format: "%.1f", lufs)) LUFS")
                    .foregroundStyle(PMWColors.pencilCool)
            }
        }
        .font(PMWFont.mono(11))
        .kerning(0.6)
        .padding(.top, 12).padding(.bottom, 14)
        .overlay(alignment: .bottom) { PMWRule() }
    }

    private func transport(asset: PMWAPIClient.APIAsset?, song: PMWAPIClient.APISong, current: PMWAPIClient.APIVersion) -> some View {
        HStack(spacing: 14) {
            Button {
                guard let asset, let mySong = toPmwSong(song), let myVer = toPmwVer(current), let myAsset = toPmwAsset(asset) else { return }
                if audio.isPlaying { audio.toggle() } else { audio.play(song: mySong, version: myVer, asset: myAsset) }
            } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 48, height: 48)
            .overlay(Circle().stroke(PMWColors.inkDeep, lineWidth: 1.5))
            .foregroundStyle(PMWColors.inkDeep)

            // mini progress bar
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(PMWColors.sleeveHairline.opacity(0.6))
                        Capsule().fill(PMWColors.redline)
                            .frame(width: progressWidth(geo: geo, asset: asset))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(formatMs(audio.positionMS)).font(PMWFont.mono(11)).foregroundStyle(PMWColors.pencilCool)
                    Spacer()
                    Text(asset.map { formatMs($0.duration_ms ?? 0) } ?? "—")
                        .font(PMWFont.mono(11)).foregroundStyle(PMWColors.pencilCool)
                }
            }
        }
        .padding(.top, 18)
    }

    private func versions(payload: PMWAPIClient.SharedPayload, current: PMWAPIClient.APIVersion) -> some View {
        let versions = payload.versions.filter { $0.song_id == current.song_id }.sorted { $0.version_number < $1.version_number }
        return Group {
            if versions.count > 1 && payload.link.version_policy == "full_history" {
                FlowLayoutCompat {
                    ForEach(versions, id: \.version_id) { v in
                        let isCur = v.version_id == (activeVersionID ?? current.version_id)
                        Text("\(v.version_label ?? "v\(v.version_number)")\(v.version_id == current.version_id ? " · current" : "")")
                            .font(PMWFont.mono(11, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(isCur ? PMWColors.inkDeep : PMWColors.pencilCool)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 1)
                                    .stroke(isCur ? PMWColors.inkDeep : PMWColors.sleeveHairline, lineWidth: isCur ? 1.5 : 1)
                                    .background(RoundedRectangle(cornerRadius: 1).fill(isCur ? Color.white : Color.clear))
                            )
                            .onTapGesture { activeVersionID = v.version_id }
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private func notesList(songNotes: [PMWAPIClient.APINote]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOTES · PINNED TO CUE")
                .font(PMWFont.mono(11, weight: .semibold))
                .kerning(1.6)
                .foregroundStyle(PMWColors.pencilCool)
                .padding(.bottom, 10)

            if songNotes.isEmpty {
                Text("Be the first.")
                    .font(PMWFont.display(20, weight: .semibold))
                    .foregroundStyle(PMWColors.inkDeep)
                Text("Tap a moment in the waveform, type a note, hit ↩.")
                    .font(PMWFont.sans(13))
                    .foregroundStyle(PMWColors.pencilCool)
                    .padding(.top, 4)
            } else {
                ForEach(songNotes, id: \.note_id) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(n.author_guest_label ?? n.author_user_id ?? "Anonymous")
                                .font(PMWFont.sans(13, weight: .semibold))
                                .foregroundStyle(PMWColors.inkDeep)
                            Spacer()
                            Text(n.timestamp_start_ms.map(formatMs) ?? "general")
                                .font(PMWFont.mono(10))
                                .foregroundStyle(PMWColors.pencilCool)
                        }
                        Text(n.body ?? "")
                            .font(PMWFont.sans(14))
                            .foregroundStyle(PMWColors.inkDeep)
                            .lineSpacing(2)
                        if let pin = n.timestamp_start_ms {
                            Text("● pinned to \(formatMs(pin))")
                                .font(PMWFont.mono(10))
                                .foregroundStyle(PMWColors.redline)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 12)
                    Divider().background(PMWColors.sleeveHairline)
                }
            }
        }
        .padding(.top, 28)
    }

    private func otherSongs(payload: PMWAPIClient.SharedPayload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OTHER IN THIS LINK · \(payload.songs.count - 1)")
                .font(PMWFont.mono(11, weight: .semibold))
                .kerning(1.6)
                .foregroundStyle(PMWColors.pencilCool)
                .padding(.bottom, 8)
            ForEach(payload.songs, id: \.song_id) { song in
                if song.song_id != selectedSongID {
                    Button {
                        selectedSongID = song.song_id
                        activeVersionID = song.current_version_id
                    } label: {
                        HStack(spacing: 14) {
                            Rectangle().fill(LinearGradient(colors: [Color(red: 0.38, green: 0.36, blue: 0.31), Color(red: 0.66, green: 0.62, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 48, height: 48)
                            VStack(alignment: .leading) {
                                Text(song.title)
                                    .font(PMWFont.display(15, weight: .heavy))
                                    .foregroundStyle(PMWColors.inkDeep)
                                Text(song.artist_display_name ?? "")
                                    .font(PMWFont.mono(10))
                                    .foregroundStyle(PMWColors.pencilCool)
                            }
                            Spacer()
                            Text("\(catalogLabel(songId: song.song_id))")
                                .font(PMWFont.mono(10))
                                .foregroundStyle(PMWColors.pencilCool)
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().background(PMWColors.sleeveHairline)
                }
            }
        }
        .padding(.top, 32)
    }

    // MARK: - Composer ---------------------------------------------

    private var composer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("@ \(formatMs(audio.positionMS))")
                    .font(PMWFont.mono(10))
                    .foregroundStyle(PMWColors.pencilCool)
                TextField("Note for the producer…", text: $noteBody, axis: .horizontal)
                    .font(PMWFont.sans(15))
                    .foregroundStyle(PMWColors.inkDeep)
                    .submitLabel(.send)
                    .focused($composerFocused)
                    .onSubmit { Task { await submitNote() } }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(PMWColors.sleeveHairline, lineWidth: 1))
            )

            // Voice memo button removed — feature not yet shipped.

            Button {
                Task { await submitNote() }
            } label: {
                Text(posting ? "…" : "Note")
                    .font(PMWFont.sans(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(noteBody.trimmingCharacters(in: .whitespaces).isEmpty ? PMWColors.pencilCool : PMWColors.inkDeep)
                    )
            }
            .disabled(posting || noteBody.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(PMWColors.sleeveElevated)
        .overlay(alignment: .top) { PMWRule() }
    }

    // MARK: - Loading / mutation -----------------------------------

    private func load() async {
        do {
            let p = try await PMWAPIClient.shared.shared(token: token)
            payload = p
            selectedSongID = p.songs.first?.song_id
            activeVersionID = p.songs.first?.current_version_id
            // For demo: we don't have a public notes endpoint for share visitors.
            // The web's SharedPayload similarly omits notes — to be added when
            // /shared/:token gets a `notes` field. For now, leave empty.
            notes = []
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func submitNote() async {
        guard let song = currentSong(payload), let v = currentVersion(payload) else { return }
        let body = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        posting = true
        defer { posting = false }
        do {
            let posted = try await PMWAPIClient.shared.createNote(
                songID: song.song_id,
                versionID: v.version_id,
                body: body,
                timestampMS: audio.positionMS,
                author: "Listener"
            )
            notes.append(posted)
            noteBody = ""
            composerFocused = false
            noteJustPosted.toggle()
        } catch {
            noteError = "Note didn't send: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers ----------------------------------------------

    private func currentSong(_ payload: PMWAPIClient.SharedPayload?) -> PMWAPIClient.APISong? {
        guard let payload else { return nil }
        return payload.songs.first { $0.song_id == (selectedSongID ?? payload.songs.first?.song_id) }
    }

    private func currentVersion(_ payload: PMWAPIClient.SharedPayload?) -> PMWAPIClient.APIVersion? {
        guard let payload, let songId = selectedSongID ?? payload.songs.first?.song_id else { return nil }
        let songVersions = payload.versions.filter { $0.song_id == songId }
        return songVersions.first { $0.version_id == (activeVersionID ?? "") }
            ?? songVersions.first { $0.is_current }
            ?? songVersions.last
    }

    private func assetFor(_ id: String, in payload: PMWAPIClient.SharedPayload) -> PMWAPIClient.APIAsset? {
        payload.assets.first { $0.asset_id == id }
    }

    private func progressWidth(geo: GeometryProxy, asset: PMWAPIClient.APIAsset?) -> CGFloat {
        guard let duration = asset?.duration_ms, duration > 0 else { return 0 }
        let pct = min(1, max(0, Double(audio.positionMS) / Double(duration)))
        return geo.size.width * CGFloat(pct)
    }

    private func catalogLabel(songId: String) -> String {
        // Stable 4-digit number derived from the song id — matches PMWSong.catalogNumber
        var hash: UInt64 = 14695981039346656037
        for byte in songId.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "PB · \(String(format: "%04d", hash % 9000 + 1000))"
    }

    private func formatMs(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    // Conversion helpers to drive the shared PMWAudioEngine from API types
    private func toPmwSong(_ s: PMWAPIClient.APISong) -> PMWSong? {
        PMWSong(id: s.song_id, roomID: s.primary_room_id ?? "",
                title: s.title, artistName: s.artist_display_name ?? "",
                projectName: s.project_name ?? "", status: s.status,
                currentVersionID: s.current_version_id ?? "",
                approvedVersionID: s.approved_version_id,
                bpm: s.bpm ?? 0, songKey: s.song_key ?? "",
                explicit: s.explicit_flag ?? false)
    }
    private func toPmwVer(_ v: PMWAPIClient.APIVersion) -> PMWVersion? {
        PMWVersion(id: v.version_id, songID: v.song_id, number: v.version_number,
                   label: v.version_label ?? "v\(v.version_number)",
                   type: PMWVersionType(rawValue: v.type) ?? .mix,
                   parentVersionID: v.parent_version_id,
                   isCurrent: v.is_current, isApproved: v.is_approved,
                   assetID: v.file_asset_id, createdAt: Date())
    }
    private func toPmwAsset(_ a: PMWAPIClient.APIAsset) -> PMWAsset? {
        PMWAsset(id: a.asset_id, filename: a.original_filename,
                 durationMS: a.duration_ms ?? 0, loudnessLUFS: a.loudness_lufs ?? -14,
                 waveform: a.waveform_peaks ?? [], hasStems: a.key_stems_zip != nil,
                 assetURLPath: a.playback_url?.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

// MARK: - Compat helpers ----------------------------------------------

private extension Text {
    func inkBold() -> Text {
        self.foregroundStyle(PMWColors.inkDeep).fontWeight(.semibold)
    }
}

/// Minimal flow layout for the version pills. Replace with iOS 16's
/// `Layout` protocol if you want — this works on iOS 15+.
private struct FlowLayoutCompat<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
        }
    }
}
