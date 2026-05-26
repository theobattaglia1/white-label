import SwiftUI

/// The Song Card hero — iOS analog of the web's `.song-card-hero`.
/// Cover at top, metadata below, version pills, action buttons,
/// waveform band, three-column "below" (notes / listeners / version stack).
///
/// Drops into PMWRootView's song tab in place of the legacy `songHero`
/// block. The component is self-contained: it doesn't manage state,
/// it just renders the passed-in song/version/asset/notes/listeners,
/// and surfaces actions via closures.
///
/// To integrate, in PMWRootView's song tab, replace the legacy song
/// hero VStack with:
///
///     PMWSongCardHero(
///         song: store.selectedSong,
///         versions: store.selectedVersions,
///         currentVersion: store.currentVersion,
///         asset: store.currentAsset,
///         notes: store.visibleNotes,
///         isPlaying: audio.isPlaying,
///         positionMs: audio.positionMS,
///         onPlay: { audio.play(song: store.selectedSong, version: store.currentVersion, asset: store.currentAsset!) },
///         onPause: { audio.pause() },
///         onSelectVersion: { v in store.setCurrent(v); if let a = store.asset(for: v) { audio.play(song: store.selectedSong, version: v, asset: a) } },
///         onAddNote: { noteComposerPresented = true },
///         onUploadRevision: { store.addDemoVersion() }
///     )
struct PMWSongCardHero: View {
    let song: PMWSong
    let versions: [PMWVersion]
    let currentVersion: PMWVersion
    let asset: PMWAsset?
    let notes: [PMWVisibleNote]
    let isPlaying: Bool
    let positionMs: Int

    var onPlay: () -> Void
    var onPause: () -> Void
    var onSelectVersion: (PMWVersion) -> Void
    var onAddNote: () -> Void
    var onUploadRevision: () -> Void
    var onApprove: (() -> Void)? = nil

    private var openNotes: [PMWVisibleNote] { notes.filter { $0.note.status == .open } }
    private var hasNotesDue: Bool { !openNotes.isEmpty }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    coverPanel
                    infoPanel
                }
                wavebandPanel
                belowSegments
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle().fill(PMWColors.sleeveCard)
                    .overlay(Rectangle().stroke(PMWColors.sleeveHairline, lineWidth: 1))
            )

            // Stamp row — Approved + Notes Due stacked horizontally if both apply
            HStack(spacing: 8) {
                if song.approvedVersionID != nil,
                   let approvedLabel = versions.first(where: { $0.id == song.approvedVersionID })?.label {
                    PMWStamp(text: "Approved · \(approvedLabel)", kind: .approved, straight: true)
                        .background(PMWColors.sleeveCream)
                }
                if hasNotesDue {
                    PMWStamp(text: "Notes Due · \(openNotes.count)", kind: .notesDue)
                        .background(PMWColors.sleeveCream)
                }
            }
            .padding(EdgeInsets(top: -14, leading: 0, bottom: 0, trailing: 28))
        }
        .padding(.top, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PMWColors.sleeveCream)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: song.id)
    }

    // MARK: - Cover ----------------------------------------------------

    private var coverPanel: some View {
        ZStack(alignment: .bottomLeading) {
            // Per-song hue derived from song.id — every song gets its own face.
            pmwCoverGradient(for: song.id)
                .frame(maxWidth: .infinity)
                .aspectRatio(2.2, contentMode: .fit)
                .id(song.id) // forces fresh gradient layer for smooth crossfade
                .transition(.opacity)

            // grain
            Canvas { ctx, size in
                let step: CGFloat = 3
                for x in stride(from: 0, to: size.width, by: step) {
                    for y in stride(from: 0, to: size.height, by: step) {
                        let r = CGRect(x: x, y: y, width: 1, height: 1)
                        ctx.fill(Path(ellipseIn: r), with: .color(.white.opacity(0.04)))
                    }
                }
            }
            .blendMode(.overlay)
            .allowsHitTesting(false)

            HStack {
                PMWMonoMark(size: 22, tint: .white)
                Spacer()
            }
            .padding(.leading, 16).padding(.bottom, 12)

            // catalog strip top-left
            HStack {
                Text("\(song.catalogId) · \(currentVersion.label)")
                    .font(PMWFont.mono(11, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.black.opacity(0.55))
                Spacer()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.leading, 12).padding(.top, 12)
        }
    }

    // MARK: - Info -----------------------------------------------------

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // breadcrumb
            HStack(spacing: 4) {
                Text(song.artistName)
                    .foregroundStyle(PMWColors.inkDeep).fontWeight(.semibold)
                Text("/")
                    .foregroundStyle(PMWColors.pencilCool)
                Text(song.projectName.isEmpty ? "Untitled project" : song.projectName)
                    .foregroundStyle(PMWColors.pencilCool)
            }
            .font(PMWFont.mono(11))
            .kerning(0.8)

            // title
            Text(song.title)
                .font(PMWFont.display(46, weight: .heavy))
                .kerning(-1.4)
                .foregroundStyle(PMWColors.inkDeep)
                .fixedSize(horizontal: false, vertical: true)

            // artist + version
            Text("\(song.artistName) · \(currentVersion.label)")
                .font(PMWFont.sans(16))
                .foregroundStyle(PMWColors.pencilCool)

            // meta row
            metaRow

            // version pills
            versionPills

            // action buttons
            actionRow
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            if let ms = asset?.durationMS { metaPart(value: formatMs(ms), label: nil) }
            metaPart(value: "\(song.bpm)", label: "BPM")
            metaPart(value: song.songKey, label: nil)
            if let lufs = asset?.loudnessLUFS { Text("\(String(format: "%.1f", lufs)) LUFS").metaSecondary() }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { PMWRule() }
    }

    private func metaPart(value: String, label: String?) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(PMWFont.mono(11, weight: .semibold))
                .foregroundStyle(PMWColors.inkDeep)
            if let label {
                Text(label).metaSecondary()
            }
        }
    }

    private var versionPills: some View {
        HStack(spacing: 8) {
            Text("STACK")
                .font(PMWFont.mono(10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(PMWColors.pencilCool)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(versions) { v in
                        versionPill(v)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func versionPill(_ v: PMWVersion) -> some View {
        let isCur = v.id == currentVersion.id
        let isApproved = v.id == song.approvedVersionID
        Button { onSelectVersion(v) } label: {
            HStack(spacing: 6) {
                if isCur {
                    Circle()
                        .fill(PMWColors.redline)
                        .frame(width: 5, height: 5)
                }
                Text(v.label.uppercased())
                    .font(PMWFont.mono(10, weight: .semibold))
                    .kerning(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(isCur ? PMWColors.inkDeep : PMWColors.pencilCool)
                if isApproved && !isCur {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PMWColors.inkDeep)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 1)
                    .stroke(isCur ? PMWColors.inkDeep : PMWColors.sleeveHairline, lineWidth: isCur ? 1.5 : 1)
                    .background(RoundedRectangle(cornerRadius: 1).fill(isCur ? Color.white : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(v.label)\(isCur ? ", current" : "")\(isApproved ? ", approved" : "")")
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PMWChromeButtonStyle(variant: .accent))
            .accessibilityLabel("Play \(currentVersion.label)")

            Button(action: onUploadRevision) {
                Label("Revision", systemImage: "plus.circle")
            }
            .buttonStyle(PMWChromeButtonStyle(variant: .ghost))
            .accessibilityLabel("Upload new revision")

            ShareLink(item: shareURL,
                      subject: Text("\(song.title) · \(currentVersion.label)"),
                      message: Text("\(song.artistName) — \(song.catalogId) · \(currentVersion.label)")) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Share")
                        .font(PMWFont.sans(13, weight: .semibold))
                }
                .foregroundStyle(PMWColors.inkDeep)
                .frame(height: 40)
                .padding(.horizontal, 4)
            }
            .accessibilityLabel("Share private link")

            Button(action: onAddNote) {
                HStack(spacing: 5) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Note")
                        .font(PMWFont.sans(13, weight: .semibold))
                }
                .foregroundStyle(PMWColors.inkDeep)
                .frame(height: 40)
                .padding(.horizontal, 4)
            }
            .accessibilityLabel("Add note")
        }
        .padding(.top, 6)
    }

    /// Best-effort share URL — uses the seeded room-demo token until per-song
    /// share-link minting is wired (next-session work). The recipient surface
    /// resolves the song from the link's target_id, so this works correctly
    /// for the demo dataset.
    private var shareURL: URL {
        PMWConfig.apiBaseURL.appendingPathComponent("shared/room-demo")
    }

    // MARK: - Waveband -------------------------------------------------

    private var wavebandPanel: some View {
        HStack(spacing: 14) {
            Button { isPlaying ? onPause() : onPlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .background(Circle().fill(PMWColors.inkDeep))
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            waveformView

            Text("\(formatMs(positionMs)) / \(formatMs(asset?.durationMS ?? 0))")
                .font(PMWFont.mono(12))
                .foregroundStyle(PMWColors.pencilCool)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(PMWColors.sleeveElevated)
        .overlay(alignment: .top) { PMWRule() }
        .overlay(alignment: .bottom) { PMWRule() }
    }

    private var waveformView: some View {
        GeometryReader { geo in
            let peaks = asset?.waveform.isEmpty == false ? asset!.waveform :
                        Array(repeating: 0.4, count: 64)
            let progress = asset.map { Double(positionMs) / max(1, Double($0.durationMS)) } ?? 0
            let barWidth = max(2, (geo.size.width - CGFloat(peaks.count - 1) * 2) / CGFloat(peaks.count))

            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { (i, p) in
                    let position = Double(i) / Double(max(1, peaks.count - 1))
                    let isPassed = position < progress
                    let isCue = abs(position - progress) < 0.012
                    Rectangle()
                        .fill(isCue ? PMWColors.redline
                              : (isPassed ? PMWColors.inkDeep : PMWColors.inkDeep.opacity(0.5)))
                        .frame(width: barWidth, height: max(4, 36 * CGFloat(p)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("Playback waveform, \(formatMs(positionMs)) of \(formatMs(asset?.durationMS ?? 0))")
        .accessibilityAdjustableAction { _ in /* future: scrub via VoiceOver swipe */ }
    }

    // MARK: - Below: segmented Notes / Stack / Readiness panel ---------

    private enum BelowSection: String, CaseIterable, Identifiable {
        case notes, stack, readiness
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notes: return "Notes"
            case .stack: return "Stack"
            case .readiness: return "Ready"
            }
        }
    }
    @State private var belowSection: BelowSection = .notes

    private var belowSegments: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Custom segmented control — brand consistent (no native .segmented chrome)
            HStack(spacing: 0) {
                ForEach(BelowSection.allCases) { section in
                    let isActive = belowSection == section
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            belowSection = section
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(section.label.uppercased())
                                .font(PMWFont.mono(10, weight: .semibold))
                                .kerning(1.4)
                                .foregroundStyle(isActive ? PMWColors.inkDeep : PMWColors.pencilCool)
                            Rectangle()
                                .fill(isActive ? PMWColors.redline : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottom) { PMWRule() }

            Group {
                switch belowSection {
                case .notes: notesSection
                case .stack: stackSection
                case .readiness: readinessSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .padding(.top, 6)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if openNotes.isEmpty {
                Text("No open notes.")
                    .font(PMWFont.sans(14))
                    .foregroundStyle(PMWColors.pencilCool)
            } else {
                ForEach(openNotes) { vn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(vn.note.author.uppercased())
                                .font(PMWFont.mono(10, weight: .bold))
                                .kerning(1.2)
                                .foregroundStyle(PMWColors.pencilCool)
                            Spacer()
                            Text("\(vn.isCarried ? "≈ " : "")\(formatMs(vn.note.timestampStartMS ?? 0))")
                                .font(PMWFont.mono(10))
                                .foregroundStyle(vn.approximateTimestamp ? PMWColors.warning : PMWColors.pencilCool)
                        }
                        Text(vn.note.body)
                            .font(PMWFont.sans(14))
                            .foregroundStyle(PMWColors.inkDeep)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                    if vn.id != openNotes.last?.id { Divider().background(PMWColors.sleeveHairline) }
                }
            }
        }
    }

    private var stackSection: some View {
        VStack(spacing: 0) {
            ForEach(versions) { v in
                let isCur = v.id == currentVersion.id
                let isApproved = v.id == song.approvedVersionID
                let assetForVersion = v.assetID
                let durationLabel: String = {
                    // Per-version duration if we can find its asset; fallback to current asset's duration only when nil
                    if let a = asset, a.id == assetForVersion { return formatMs(a.durationMS) }
                    return "—"
                }()
                HStack(spacing: 12) {
                    Text(String(format: "%02d", v.number))
                        .font(PMWFont.mono(11, weight: .bold))
                        .foregroundStyle(PMWColors.redline)
                        .frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.label)
                            .font(PMWFont.sans(14, weight: .semibold))
                            .foregroundStyle(PMWColors.inkDeep)
                        Text(v.type.title.uppercased())
                            .font(PMWFont.mono(10))
                            .kerning(0.8)
                            .foregroundStyle(PMWColors.pencilCool)
                    }
                    Spacer()
                    if isApproved {
                        PMWStamp(text: "Approved", kind: .approved, tight: true, straight: true)
                    }
                    if isCur {
                        HStack(spacing: 5) {
                            Circle().fill(PMWColors.redline).frame(width: 6, height: 6)
                            Text("CURRENT")
                                .font(PMWFont.mono(10, weight: .bold))
                                .kerning(1.2)
                                .foregroundStyle(PMWColors.redline)
                        }
                    } else {
                        Text(durationLabel)
                            .font(PMWFont.mono(10))
                            .foregroundStyle(PMWColors.pencilCool)
                    }
                }
                .padding(.vertical, 10)
                if v.id != versions.last?.id { Divider().background(PMWColors.sleeveHairline) }
            }
        }
    }

    /// Release readiness — derives presence/missing from the song's data.
    /// Mirrors `PMWStore.deliverables(for:)` so the hero can render without
    /// needing the store passed in.
    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let types = Set(versions.map(\.type))
            let hasStems = false // not derivable from PMWVisibleNote slice; conservatively false
            let rows: [(String, Bool)] = [
                ("BPM", song.bpm > 0),
                ("Key", !song.songKey.isEmpty),
                ("Clean", types.contains(.clean)),
                ("Explicit", types.contains(.explicit) || !song.explicit),
                ("Instrumental", types.contains(.instrumental)),
                ("Acapella", types.contains(.acapella)),
                ("Stems", hasStems),
            ]
            HStack(spacing: 8) {
                Image(systemName: rows.allSatisfy(\.1) ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(rows.allSatisfy(\.1) ? PMWColors.inkDeep : PMWColors.pencilCool)
                Text(rows.allSatisfy(\.1) ? "Ready to ship" : "Not ready")
                    .font(PMWFont.display(20, weight: .heavy))
                    .foregroundStyle(PMWColors.inkDeep)
            }
            FlowLayout(spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 5) {
                        Image(systemName: row.1 ? "checkmark.circle" : "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(row.1 ? PMWColors.redline : PMWColors.pencilCool.opacity(0.6))
                        Text(row.0.uppercased())
                            .font(PMWFont.mono(10, weight: .semibold))
                            .kerning(1.0)
                            .strikethrough(!row.1, color: PMWColors.pencilCool.opacity(0.55))
                            .foregroundStyle(row.1 ? PMWColors.inkDeep : PMWColors.pencilCool)
                    }
                }
            }
        }
    }

    // MARK: - Helpers ---------------------------------------------

    private func formatMs(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private extension Text {
    func metaSecondary() -> some View {
        self.font(PMWFont.mono(11))
            .foregroundStyle(PMWColors.pencilCool)
    }
}
