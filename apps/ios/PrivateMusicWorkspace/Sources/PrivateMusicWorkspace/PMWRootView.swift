import SwiftUI

struct PMWRootView: View {
    @StateObject private var store = PMWStore()
    @StateObject private var audio = PMWAudioEngine()
    @State private var noteComposerPresented = false
    @State private var noteDraft = ""
    @State private var moreSheetPresented = false

    var body: some View {
        ZStack {
            PMWColors.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                content
                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: store.selectedTab)
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if audio.song != nil {
                    miniPlayer
                    PMWRule()
                }
                bottomTabs
            }
            .background(PMWColors.canvas)
        }
        .sheet(isPresented: $noteComposerPresented) {
            noteComposer
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $moreSheetPresented) {
            moreSheet
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: audio.isPlaying)
        .sensoryFeedback(.selection, trigger: store.selectedTab)
        .sensoryFeedback(.success, trigger: store.songs.count)
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {} label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                        Circle()
                            .fill(PMWColors.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: 7, y: -7)
                    }
                }
                .buttonStyle(PMWIconButtonStyle(active: true))
                .accessibilityLabel("Notifications, 1 unread")

                Button {} label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(PMWIconButtonStyle())
                .accessibilityLabel("Search workspace")

                Button {} label: {
                    HStack(spacing: 8) {
                        Text("PMW")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(PMWColors.accent)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(PMWColors.ink))

                        Text(store.room.title.uppercased())
                            .font(PMWFont.t3(.bold))
                            .tracking(1.2)
                            .foregroundStyle(PMWColors.accent)
                            .lineLimit(1)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(PMWColors.muted)
                    }
                    .frame(maxWidth: 210)
                }
                .buttonStyle(PMWChromeButtonStyle())

                Spacer()

                Button {} label: {
                    Text("TB")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(PMWColors.accent)
                        .frame(width: 31, height: 31)
                        .background(Circle().fill(PMWColors.ink))
                }
                .buttonStyle(PMWIconButtonStyle(active: true))
                .accessibilityLabel("Theo Battaglia — account")
            }
            .padding(.horizontal, PMWSpacing.page)
            .padding(.vertical, 8)

            PMWRule()
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PMWSpacing.section) {
                switch store.selectedTab {
                case .room:
                    PMWRoomView(store: store, audio: audio)
                case .song:
                    PMWSongView(store: store, audio: audio, onAddNote: {
                        noteComposerPresented = true
                    })
                case .compare:
                    PMWComparisonView(store: store, audio: audio)
                case .inbox:
                    PMWInboxView(store: store)
                case .links:
                    PMWLinksView(store: store)
                case .ask:
                    PMWAskView(store: store)
                }
            }
            .pmwScreen()
            .padding(.top, PMWSpacing.stack)
            .padding(.bottom, 132)
        }
    }

    private var bottomTabs: some View {
        HStack(spacing: 0) {
            ForEach(PMWTab.primary) { tab in
                tabButton(tab)
            }
            // "More" — opens a sheet exposing Compare / Links / Ask.
            Button {
                moreSheetPresented = true
            } label: {
                VStack(spacing: 4) {
                    let activeSecondary = !store.selectedTab.isPrimary
                    Image(systemName: activeSecondary ? store.selectedTab.symbol : "ellipsis.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Text(activeSecondary ? store.selectedTab.title.uppercased() : "MORE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.1)
                }
                .foregroundStyle(store.selectedTab.isPrimary ? PMWColors.muted : PMWColors.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More — Compare, Links, Ask")
        }
        .overlay(alignment: .top) {
            // Active-tab redline — picks up the underline-cursor language from the wordmark.
            GeometryReader { geo in
                let count = CGFloat(PMWTab.primary.count + 1)
                let cellWidth = geo.size.width / count
                let activeIndex: Int = {
                    if let idx = PMWTab.primary.firstIndex(of: store.selectedTab) { return idx }
                    return PMWTab.primary.count // More slot
                }()
                Rectangle()
                    .fill(PMWColors.redline)
                    .frame(width: 28, height: 2)
                    .offset(x: CGFloat(activeIndex) * cellWidth + (cellWidth - 28) / 2)
                    .animation(.spring(response: 0.28, dampingFraction: 0.75), value: store.selectedTab)
            }
            .frame(height: 2)
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: PMWTab) -> some View {
        Button {
            store.selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(tab.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.1)
            }
            .foregroundStyle(store.selectedTab == tab ? PMWColors.accent : PMWColors.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(store.selectedTab == tab ? .isSelected : [])
    }

    private var moreSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MORE")
                .font(PMWFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(PMWColors.accent)
                .padding(.bottom, 12)
                .padding(.top, 12)
            ForEach(PMWTab.secondary) { tab in
                Button {
                    store.selectedTab = tab
                    moreSheetPresented = false
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 28)
                            .foregroundStyle(PMWColors.ink)
                        Text(tab.title)
                            .font(PMWFont.display(22, weight: .heavy))
                            .foregroundStyle(PMWColors.ink)
                        Spacer()
                        if store.selectedTab == tab {
                            Image(systemName: "checkmark")
                                .foregroundStyle(PMWColors.accent)
                        }
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                PMWRule()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PMWSpacing.page)
        .background(PMWColors.canvas)
        .preferredColorScheme(.dark)
    }

    private var miniPlayer: some View {
        HStack(spacing: 12) {
            Button {
                audio.toggle()
            } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(PMWIconButtonStyle(active: true))

            VStack(alignment: .leading, spacing: 2) {
                Text(audio.song?.title ?? "Player")
                    .font(PMWFont.t2(.semibold))
                    .lineLimit(1)
                Text("\(audio.version?.label ?? "") · \(pmwTimestamp(audio.positionMS))")
                    .font(PMWFont.t3())
                    .tracking(0.8)
                    .foregroundStyle(PMWColors.muted)
                    .lineLimit(1)
            }

            Spacer()

            if let asset = audio.asset {
                PMWWaveform(asset: asset, positionMS: audio.positionMS, compact: true) { nextPosition in
                    audio.seek(to: nextPosition)
                }
                .frame(width: 118, height: 36)
            }
        }
        .padding(.horizontal, PMWSpacing.page)
        .padding(.vertical, 8)
    }

    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.compact) {
            Text("NOTE AT \(pmwTimestamp(audio.positionMS))")
                .font(PMWFont.t3(.bold))
                .tracking(2)
                .foregroundStyle(PMWColors.accent)

            TextField("Write the note", text: $noteDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(PMWFont.t2())
                .lineLimit(3, reservesSpace: true)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    PMWRule()
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    noteComposerPresented = false
                    noteDraft = ""
                }
                .buttonStyle(PMWChromeButtonStyle())

                Button("Send") {
                    store.addNote(body: noteDraft, timestampMS: audio.positionMS)
                    noteDraft = ""
                    noteComposerPresented = false
                }
                .buttonStyle(PMWChromeButtonStyle(accent: true))
            }
        }
        .padding(PMWSpacing.page)
        .background(PMWColors.canvas)
    }
}

struct PMWRoomView: View {
    @ObservedObject var store: PMWStore
    @ObservedObject var audio: PMWAudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.stack) {
            PMWSectionHeader(eyebrow: "ROOM", title: store.room.title) {
                HStack(spacing: 1) {
                    PMWMetric(value: "\(store.songs.count)", label: "Songs")
                    PMWMetric(value: "\(store.versions.count)", label: "Versions")
                    PMWMetric(value: "\(store.notes.filter { $0.status == .open }.count)", label: "Open")
                }
            }

            VStack(spacing: 0) {
                PMWRule()
                ForEach(store.songs) { song in
                    let current = store.versions.first { $0.id == song.currentVersionID }
                    let asset = store.asset(for: current)
                    Button {
                        store.selectSong(song)
                    } label: {
                        HStack(spacing: PMWSpacing.compact) {
                            PMWCoverMark(songID: song.id)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.title)
                                    .font(PMWFont.t2(.bold))
                                    .foregroundStyle(PMWColors.ink)
                                Text("\(song.artistName) · \(current?.label ?? "No version")")
                                    .font(PMWFont.t3())
                                    .tracking(0.8)
                                    .foregroundStyle(PMWColors.muted)
                            }
                            Spacer()
                            if let asset {
                                PMWWaveform(asset: asset, positionMS: 0, compact: true) { _ in }
                                    .frame(width: 96, height: 38)
                            }
                        }
                        .padding(.vertical, PMWSpacing.compact)
                    }
                    .buttonStyle(.plain)
                    PMWRule()
                }
            }
        }
    }
}

struct PMWSongView: View {
    @ObservedObject var store: PMWStore
    @ObservedObject var audio: PMWAudioEngine
    let onAddNote: () -> Void
    @State private var activeVersionID: String?

    private var activeVersion: PMWVersion? {
        let candidate = activeVersionID ?? store.currentVersion?.id
        return store.selectedVersions.first { $0.id == candidate } ?? store.currentVersion
    }

    var body: some View {
        if let current = store.currentVersion {
            VStack(alignment: .leading, spacing: PMWSpacing.stack) {
                // ----- Editorial Song Card hero (cover + metadata + waveband + columns) -----
                PMWSongCardHero(
                    song: store.selectedSong,
                    versions: store.selectedVersions,
                    currentVersion: current,
                    asset: store.currentAsset,
                    notes: store.visibleNotes,
                    isPlaying: audio.isPlaying,
                    positionMs: audio.positionMS,
                    onPlay: {
                        if let asset = store.currentAsset {
                            audio.play(song: store.selectedSong, version: current, asset: asset)
                        }
                    },
                    onPause: { audio.pause() },
                    onSelectVersion: { v in
                        store.setCurrent(v)
                        activeVersionID = v.id
                        if let a = store.asset(for: v) {
                            audio.play(song: store.selectedSong, version: v, asset: a)
                        }
                    },
                    onAddNote: onAddNote,
                    onUploadRevision: { store.addDemoVersion() }
                )

                // ----- Supplementary panels (still useful below the hero) -----
                VStack(spacing: PMWSpacing.stack) {
                    versionStack
                    notesPanel
                    deliverablesPanel
                }
            }
            .onAppear {
                activeVersionID = current.id
            }
        } else {
            songEmptyState
        }
    }

    private var songEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(PMWColors.muted)
            Text("No versions yet")
                .font(PMWFont.display(28, weight: .heavy))
                .foregroundStyle(PMWColors.ink)
            Text("Upload a mix to start the version stack for this song.")
                .font(PMWFont.sans(14))
                .foregroundStyle(PMWColors.muted)
                .multilineTextAlignment(.center)
            Button("Upload first mix") { store.addDemoVersion() }
                .buttonStyle(PMWChromeButtonStyle(variant: .accent))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var versionStack: some View {
        PMWPanel(eyebrow: "VERSION STACK", title: "History", symbol: "clock.arrow.circlepath") {
            VStack(spacing: 0) {
                ForEach(store.selectedVersions) { version in
                    Button {
                        activeVersionID = version.id
                        if let asset = store.asset(for: version) {
                            audio.play(song: store.selectedSong, version: version, asset: asset)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(String(format: "%02d", version.number))
                                .font(PMWFont.t3(.black))
                                .tracking(1)
                                .foregroundStyle(PMWColors.accent)
                                .frame(width: 28, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(version.label)
                                    .font(PMWFont.t2(.bold))
                                    .foregroundStyle(PMWColors.ink)
                                Text("\(version.type.title) · \(store.asset(for: version)?.loudnessLUFS ?? 0, specifier: "%.1f") LUFS")
                                    .font(PMWFont.t3())
                                    .tracking(0.8)
                                    .foregroundStyle(PMWColors.muted)
                            }

                            Spacer()

                            if version.isCurrent {
                                PMWBadge("Current", accent: true)
                            } else {
                                Button("Set") {
                                    store.setCurrent(version)
                                    activeVersionID = version.id
                                }
                                .font(PMWFont.t3(.bold))
                                .foregroundStyle(PMWColors.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    PMWRule()
                }
            }
        }
    }

    private var notesPanel: some View {
        PMWPanel(eyebrow: "NOTES", title: "\(store.visibleNotes.filter { $0.note.status == .open }.count) Open", symbol: "text.bubble") {
            VStack(spacing: 0) {
                ForEach(store.visibleNotes) { visible in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(visible.note.author.uppercased())
                            Spacer()
                            Text(visible.isCarried ? "CARRIED FROM \(visible.anchorLabel.uppercased())" : "FROM \(visible.anchorLabel.uppercased())")
                        }
                        .font(PMWFont.t3(.bold))
                        .tracking(1)
                        .foregroundStyle(PMWColors.muted)

                        Text(visible.note.body)
                            .font(PMWFont.t2())
                            .foregroundStyle(PMWColors.ink.opacity(visible.isCollapsed ? 0.62 : 1))

                        HStack {
                            Text("\(visible.approximateTimestamp ? "≈ " : "")\(pmwTimestamp(visible.note.timestampStartMS))\(visible.approximateTimestamp ? ", position may have shifted" : "")")
                                .foregroundStyle(visible.approximateTimestamp ? PMWColors.warning : PMWColors.muted)
                            Spacer()
                            Button(visible.note.status == .open ? "Resolve" : "Reopen") {
                                visible.note.status == .open ? store.resolve(visible) : store.reopen(visible)
                            }
                            .foregroundStyle(PMWColors.accent)
                        }
                        .font(PMWFont.t3(.bold))
                        .tracking(1)
                    }
                    .padding(.vertical, 14)
                    PMWRule()
                }
            }
        }
    }

    private var deliverablesPanel: some View {
        let status = store.deliverables(for: store.selectedSong)
        return PMWPanel(eyebrow: "RELEASE READINESS", title: status.ready ? "Ready" : "Not Ready", symbol: status.ready ? "checkmark.circle" : "circle.dashed") {
            FlowLayout(spacing: 8) {
                ForEach(status.present, id: \.self) { item in
                    PMWChecklistBadge(item, present: true)
                }
                ForEach(status.missing, id: \.self) { item in
                    PMWChecklistBadge(item, present: false)
                }
            }
            .padding(.top, 10)
        }
    }
}

struct PMWComparisonView: View {
    @ObservedObject var store: PMWStore
    @ObservedObject var audio: PMWAudioEngine

    var leftVersion: PMWVersion? { store.versions.first { $0.id == store.comparisonLeftID } }
    var rightVersion: PMWVersion? { store.versions.first { $0.id == store.comparisonRightID } }

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.stack) {
            PMWSectionHeader(eyebrow: "COMPARISON MODE", title: store.selectedSong.title) {
                Toggle("Loudness Match", isOn: $audio.loudnessMatched)
                    .font(PMWFont.t3(.bold))
                    .tracking(1)
                    .toggleStyle(.switch)
            }

            comparisonDeck(title: "A", versionID: $store.comparisonLeftID, version: leftVersion)
            comparisonDeck(title: "B", versionID: $store.comparisonRightID, version: rightVersion)
        }
    }

    private func comparisonDeck(title: String, versionID: Binding<String>, version: PMWVersion?) -> some View {
        PMWPanel(eyebrow: "DECK \(title)", title: version?.label ?? "Version", symbol: "waveform") {
            Picker("Version", selection: versionID) {
                ForEach(store.selectedVersions) { version in
                    Text(version.label).tag(version.id)
                }
            }
            .pickerStyle(.menu)

            if let version, let asset = store.asset(for: version) {
                PMWWaveform(asset: asset, positionMS: audio.positionMS, compact: false) { nextPosition in
                    audio.seek(to: nextPosition)
                }
                .frame(height: 104)

                HStack {
                    Button {
                        audio.play(song: store.selectedSong, version: version, asset: asset)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PMWChromeButtonStyle(accent: true))

                    Spacer()

                    Text("\(asset.loudnessLUFS, specifier: "%.1f") LUFS · gain \(audio.gainOffset(for: asset), specifier: "%.1f") dB")
                        .font(PMWFont.t3(.bold))
                        .tracking(1)
                        .foregroundStyle(PMWColors.muted)
                }
            }
        }
    }
}

struct PMWInboxView: View {
    @ObservedObject var store: PMWStore

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.stack) {
            PMWSectionHeader(eyebrow: "EXECUTIVE INBOX", title: "Received Music") {
                HStack(spacing: 1) {
                    PMWMetric(value: "\(store.inboxItems.filter { $0.newSinceLastListen }.count)", label: "New")
                    PMWMetric(value: "\(store.inboxItems.filter { $0.offlineQueued }.count)", label: "Offline")
                }
            }

            VStack(spacing: 0) {
                PMWRule()
                ForEach(store.inboxItems) { item in
                    Button {
                        store.selectSong(item.song)
                    } label: {
                        HStack(spacing: PMWSpacing.compact) {
                            PMWCoverMark(songID: item.song.id)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.song.title)
                                    .font(PMWFont.t2(.bold))
                                    .foregroundStyle(PMWColors.ink)
                                Text("Shared by \(item.sharedBy) · \(item.currentVersion.label)")
                                    .font(PMWFont.t3())
                                    .tracking(0.8)
                                    .foregroundStyle(PMWColors.muted)
                            }
                            Spacer()
                            PMWBadge(item.newSinceLastListen ? "New" : "Heard", accent: item.newSinceLastListen)
                        }
                        .padding(.vertical, PMWSpacing.compact)
                    }
                    .buttonStyle(.plain)
                    PMWRule()
                }
            }
        }
    }
}

struct PMWLinksView: View {
    @ObservedObject var store: PMWStore

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.stack) {
            PMWSectionHeader(eyebrow: "SHARE LINKS", title: "Policy Engine") {
                Button {} label: {
                    Label("Create Link", systemImage: "plus")
                }
                .buttonStyle(PMWChromeButtonStyle(accent: true))
            }

            PMWPanel(eyebrow: "ROOM", title: "Artist + manager latest room", symbol: "link") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        PMWBadge("Identity Required", accent: true)
                        PMWBadge("Latest Only", accent: false)
                        PMWBadge("No Downloads", accent: false)
                    }
                    Text("Watermarking is shown as leak deterrence and tracing, never prevention.")
                        .font(PMWFont.t2())
                        .foregroundStyle(PMWColors.muted)
                    HStack {
                        Button("Open") {}
                            .buttonStyle(PMWChromeButtonStyle())
                        Button("Revoke") {}
                            .buttonStyle(PMWChromeButtonStyle())
                    }
                }
            }
        }
    }
}

struct PMWAskView: View {
    @ObservedObject var store: PMWStore
    @State private var question = "Who hasn't heard v2?"
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.stack) {
            PMWSectionHeader(eyebrow: "READ-ONLY ASK", title: "Workspace Questions") {
                Image(systemName: "shield")
                    .foregroundStyle(PMWColors.accent)
            }

            VStack(alignment: .leading, spacing: PMWSpacing.compact) {
                TextField("Question", text: $question)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { PMWRule() }

                Button("Ask") {
                    answer = store.assistantAnswer(for: question)
                }
                .buttonStyle(PMWChromeButtonStyle(accent: true))
            }

            Text(answer.isEmpty ? store.assistantAnswer(for: question) : answer)
                .font(PMWFont.t2())
                .lineSpacing(4)
                .foregroundStyle(PMWColors.ink)
                .padding(.vertical, PMWSpacing.compact)
                .overlay(alignment: .top) { PMWRule() }
                .overlay(alignment: .bottom) { PMWRule() }
        }
    }
}

struct PMWSectionHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let trailing: Trailing

    init(eyebrow: String, title: String, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.compact) {
            HStack {
                Text(eyebrow)
                    .font(PMWFont.t3(.bold))
                    .tracking(2)
                    .foregroundStyle(PMWColors.accent)
                Spacer()
                trailing
            }
            Text(title)
                .font(PMWFont.display(36, weight: .heavy))
                .kerning(-0.6)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(PMWColors.ink)
        }
    }
}

struct PMWPanel<Content: View>: View {
    let eyebrow: String
    let title: String
    let symbol: String
    let content: Content

    init(eyebrow: String, title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.compact) {
            PMWRule()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(eyebrow)
                        .font(PMWFont.t3(.bold))
                        .tracking(2)
                        .foregroundStyle(PMWColors.accent)
                    Text(title)
                        .font(.title3.weight(.bold))
                }
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(PMWColors.muted)
            }
            content
            PMWRule()
        }
    }
}

struct PMWMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title2.weight(.black))
                .foregroundStyle(PMWColors.ink)
            Text(label.uppercased())
                .font(PMWFont.t3(.bold))
                .tracking(1)
                .foregroundStyle(PMWColors.muted)
        }
        .frame(minWidth: 74, alignment: .leading)
        .padding(10)
        .overlay(Rectangle().stroke(PMWColors.line, lineWidth: 1))
    }
}

struct PMWBadge: View {
    let title: String
    let accent: Bool

    init(_ title: String, accent: Bool) {
        self.title = title
        self.accent = accent
    }

    var body: some View {
        HStack(spacing: 5) {
            if accent {
                Circle()
                    .fill(PMWColors.redline)
                    .frame(width: 7, height: 7)
            }
            Text(title.uppercased())
                .font(PMWFont.mono(10, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(accent ? PMWColors.redline : PMWColors.muted)
        }
    }
}

struct PMWChecklistBadge: View {
    let title: String
    let present: Bool

    init(_ title: String, present: Bool) {
        self.title = title
        self.present = present
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: present ? "checkmark.circle" : "xmark")
            Text(title.uppercased())
        }
        .font(PMWFont.t3(.bold))
        .tracking(1)
        .foregroundStyle(present ? PMWColors.success : PMWColors.accent)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(PMWColors.line, lineWidth: 1))
    }
}

/// Per-song cover swatch — replaces the two-letter initials placeholder.
/// The hue is derived from the song id via `pmwCoverGradient`, matching
/// the hero cover and the recipient page so a song has one visual identity
/// across every surface it appears on.
struct PMWCoverMark: View {
    let songID: String

    init(songID: String) { self.songID = songID }
    /// Back-compat: the old signature took two letters; we accept it and
    /// ignore the text — the gradient is keyed off the song id passed in.
    init(text: String, songID: String) { self.songID = songID }

    var body: some View {
        pmwCoverGradient(for: songID)
            .frame(width: 52, height: 52)
            .overlay(Rectangle().stroke(PMWColors.lineStrong.opacity(0.35), lineWidth: 1))
    }
}

struct PMWWaveform: View {
    let asset: PMWAsset
    let positionMS: Int
    var compact = false
    let onSeek: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let progress = min(1, max(0, CGFloat(positionMS) / CGFloat(max(asset.durationMS, 1))))
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: compact ? 2 : 3) {
                    ForEach(Array(asset.waveform.enumerated()), id: \.offset) { index, peak in
                        RoundedRectangle(cornerRadius: compact ? 0 : 1)
                            .fill(CGFloat(index) / CGFloat(max(asset.waveform.count, 1)) <= progress ? PMWColors.accent : PMWColors.ink.opacity(0.28))
                            .frame(height: max(5, CGFloat(peak) * (compact ? 34 : 88)))
                    }
                }
                Rectangle()
                    .fill(PMWColors.ink)
                    .frame(width: 1)
                    .offset(x: proxy.size.width * progress)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let ratio = min(1, max(0, value.location.x / max(proxy.size.width, 1)))
                        onSeek(Int(ratio * CGFloat(asset.durationMS)))
                    }
            )
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var size = CGSize.zero
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let viewSize = subview.sizeThatFits(.unspecified)
            if lineWidth + viewSize.width > maxWidth {
                size.width = max(size.width, lineWidth)
                size.height += lineHeight + spacing
                lineWidth = viewSize.width + spacing
                lineHeight = viewSize.height
            } else {
                lineWidth += viewSize.width + spacing
                lineHeight = max(lineHeight, viewSize.height)
            }
        }
        size.width = max(size.width, lineWidth)
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let viewSize = subview.sizeThatFits(.unspecified)
            if origin.x + viewSize.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(width: viewSize.width, height: viewSize.height))
            origin.x += viewSize.width + spacing
            lineHeight = max(lineHeight, viewSize.height)
        }
    }
}

#Preview {
    PMWRootView()
}
