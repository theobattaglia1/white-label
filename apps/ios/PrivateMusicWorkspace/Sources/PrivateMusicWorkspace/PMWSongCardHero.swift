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
            // CARD background
            VStack(alignment: .leading, spacing: 0) {
                // ----- Cover + Info row -----
                VStack(alignment: .leading, spacing: 0) {
                    coverPanel
                    infoPanel
                }
                // ----- Waveform band -----
                wavebandPanel
                // ----- Below: notes / listeners / version stack -----
                belowColumns
            }
            .background(
                Rectangle().fill(PMWColors.sleeveCard)
                    .overlay(Rectangle().stroke(PMWColors.sleeveHairline, lineWidth: 1))
            )

            // NOTES DUE stamp overlapping top edge
            if hasNotesDue {
                PMWStamp(text: "Notes Due · \(openNotes.count)", kind: .notesDue, tight: false)
                    .padding(EdgeInsets(top: -14, leading: 0, bottom: 0, trailing: 28))
                    .background(PMWColors.sleeveCream)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .background(PMWColors.sleeveCream)
    }

    // MARK: - Cover ----------------------------------------------------

    private var coverPanel: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.17, green: 0.16, blue: 0.14),
                    Color(red: 0.37, green: 0.34, blue: 0.28),
                    Color(red: 0.66, green: 0.62, blue: 0.55),
                    Color(red: 0.87, green: 0.79, blue: 0.64),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .aspectRatio(2.2, contentMode: .fit)

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
            ForEach(versions) { v in
                let isCur = v.id == currentVersion.id
                Button { onSelectVersion(v) } label: {
                    Text("\(v.label)\(isCur ? " · current" : "")".uppercased())
                        .font(PMWFont.mono(10, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(isCur ? PMWColors.inkDeep : PMWColors.pencilCool)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 1)
                                .stroke(isCur ? PMWColors.inkDeep : PMWColors.sleeveHairline, lineWidth: isCur ? 1.5 : 1)
                                .background(RoundedRectangle(cornerRadius: 1).fill(isCur ? Color.white : Color.clear))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(PMWChromeButtonStyle(variant: .accent))

            Button(action: onUploadRevision) {
                Label("Upload revision", systemImage: "arrow.up.circle")
            }
            .buttonStyle(PMWChromeButtonStyle(variant: .dark))

            Button(action: onAddNote) {
                Label("Add note", systemImage: "text.bubble")
            }
            .buttonStyle(PMWChromeButtonStyle(variant: .ghost))
        }
        .padding(.top, 6)
    }

    // MARK: - Waveband -------------------------------------------------

    private var wavebandPanel: some View {
        HStack(spacing: 14) {
            Button { isPlaying ? onPause() : onPlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            .background(Circle().fill(PMWColors.inkDeep))

            waveformView

            Text("\(formatMs(positionMs)) / \(formatMs(asset?.durationMS ?? 0))")
                .font(PMWFont.mono(12))
                .foregroundStyle(PMWColors.pencilCool)
        }
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
                        .frame(width: barWidth, height: max(4, geo.size.height * CGFloat(p)))
                }
            }
        }
        .frame(height: 36)
    }

    // MARK: - Below columns -------------------------------------------

    private var belowColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            column(title: "NOTES · \(openNotes.count) OPEN") {
                ForEach(openNotes.prefix(3)) { vn in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vn.note.body)
                            .font(PMWFont.sans(13))
                            .foregroundStyle(PMWColors.inkDeep)
                            .lineLimit(2)
                        Text("\(vn.note.author) · \(formatMs(vn.note.timestampStartMS ?? 0))")
                            .font(PMWFont.mono(10))
                            .foregroundStyle(PMWColors.pencilCool)
                    }
                    .padding(.vertical, 6)
                    if vn.id != openNotes.prefix(3).last?.id { Divider().background(PMWColors.sleeveHairline) }
                }
                if openNotes.isEmpty {
                    Text("No open notes.")
                        .font(PMWFont.sans(13))
                        .foregroundStyle(PMWColors.pencilCool)
                }
            }
            verticalRule
            column(title: "LISTENERS · \(versions.count)") {
                ForEach(versions.prefix(4)) { v in
                    HStack {
                        Text(v.label)
                            .font(PMWFont.sans(12, weight: .semibold))
                            .foregroundStyle(PMWColors.inkDeep)
                        Spacer()
                        Text(v.isCurrent ? "current" : "history")
                            .font(PMWFont.mono(10))
                            .foregroundStyle(PMWColors.pencilCool)
                    }
                    .padding(.vertical, 5)
                }
            }
            verticalRule
            column(title: "VERSION STACK · \(versions.count)") {
                ForEach(versions) { v in
                    HStack {
                        Text(v.label)
                            .font(PMWFont.sans(12, weight: .semibold))
                            .foregroundStyle(PMWColors.inkDeep)
                        Spacer()
                        Text(formatMs((asset?.durationMS ?? 0)))
                            .font(PMWFont.mono(10))
                            .foregroundStyle(PMWColors.pencilCool)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private var verticalRule: some View {
        Rectangle().fill(PMWColors.sleeveHairline).frame(width: 1)
    }

    @ViewBuilder
    private func column<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(PMWFont.mono(10, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(PMWColors.pencilCool)
                .padding(.bottom, 10)
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
