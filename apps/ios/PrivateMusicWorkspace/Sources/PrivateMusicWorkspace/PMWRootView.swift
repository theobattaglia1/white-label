import SwiftUI

struct PMWRootView: View {
    @StateObject private var store = PMWStore()
    @StateObject private var audio = PMWAudioEngine()
    @State private var noteComposerPresented = false
    @State private var noteDraft = ""

    var body: some View {
        ZStack {
            PMWColors.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                content
            }
        }
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
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
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

                Button {} label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(PMWIconButtonStyle())

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
            ForEach(PMWTab.allCases) { tab in
                Button {
                    store.selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: .semibold))
                        Text(tab.title.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.1)
                    }
                    .foregroundStyle(store.selectedTab == tab ? PMWColors.accent : PMWColors.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
                            PMWCoverMark(text: String(song.title.prefix(2)))
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

    private var activeVersion: PMWVersion {
        store.selectedVersions.first { $0.id == (activeVersionID ?? store.currentVersion.id) } ?? store.currentVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.stack) {
            PMWSectionHeader(eyebrow: "CURRENT VERSION", title: store.selectedSong.title) {
                Button {
                    store.addDemoVersion()
                } label: {
                    Label("Add Version", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PMWChromeButtonStyle())
            }

            HStack(spacing: 12) {
                Text(store.selectedSong.artistName)
                Text("\(store.selectedSong.bpm) BPM")
                Text(store.selectedSong.songKey)
                Text("\(store.currentAsset?.loudnessLUFS ?? 0, specifier: "%.1f") LUFS")
            }
            .font(PMWFont.t3(.bold))
            .tracking(1)
            .foregroundStyle(PMWColors.muted)
            .textCase(.uppercase)

            playerPanel

            VStack(spacing: PMWSpacing.stack) {
                versionStack
                notesPanel
                deliverablesPanel
            }
        }
        .onAppear {
            activeVersionID = store.currentVersion.id
        }
    }

    private var playerPanel: some View {
        VStack(alignment: .leading, spacing: PMWSpacing.compact) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activeVersion.isCurrent ? "LIVE ON SHARE LINKS" : "HISTORY")
                        .font(PMWFont.t3(.bold))
                        .tracking(2)
                        .foregroundStyle(PMWColors.accent)
                    Text(activeVersion.label)
                        .font(.title3.weight(.bold))
                }

                Spacer()

                Button {
                    onAddNote()
                } label: {
                    Image(systemName: "text.bubble")
                }
                .buttonStyle(PMWIconButtonStyle())

                Button {
                    if let asset = store.asset(for: activeVersion) {
                        audio.play(song: store.selectedSong, version: activeVersion, asset: asset)
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(PMWIconButtonStyle(active: true))
            }

            if let asset = store.asset(for: activeVersion) {
                PMWWaveform(asset: asset, positionMS: audio.positionMS, compact: false) { nextPosition in
                    audio.seek(to: nextPosition)
                    onAddNote()
                }
                .frame(height: 112)

                HStack {
                    Text(pmwTimestamp(audio.positionMS))
                    Spacer()
                    Text(pmwTimestamp(asset.durationMS))
                }
                .font(PMWFont.t3(.bold))
                .tracking(1)
                .foregroundStyle(PMWColors.muted)
            }
        }
        .padding(.vertical, PMWSpacing.compact)
        .overlay(alignment: .top) { PMWRule() }
        .overlay(alignment: .bottom) { PMWRule() }
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
                            PMWCoverMark(text: String(item.song.title.prefix(2)))
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
        HStack(alignment: .top, spacing: PMWSpacing.compact) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(PMWFont.t3(.bold))
                    .tracking(2)
                    .foregroundStyle(PMWColors.accent)
                Text(title.uppercased())
                    .font(PMWFont.t1(size: min(74, max(42, 70 - CGFloat(title.count / 3)))))
                    .lineLimit(2)
                    .minimumScaleFactor(0.64)
                    .foregroundStyle(PMWColors.ink)
            }
            Spacer(minLength: PMWSpacing.compact)
            trailing
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
        Text(title.uppercased())
            .font(PMWFont.t3(.bold))
            .tracking(1)
            .foregroundStyle(accent ? PMWColors.accent : PMWColors.muted)
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(Capsule().fill(accent ? PMWColors.accentSoft : PMWColors.soft))
            .overlay(Capsule().stroke(PMWColors.line, lineWidth: 1))
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

struct PMWCoverMark: View {
    let text: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(PMWColors.soft)
                .overlay(Rectangle().stroke(PMWColors.lineStrong.opacity(0.5), lineWidth: 1))
            Rectangle()
                .fill(PMWColors.line)
                .frame(width: 1)
            Rectangle()
                .fill(PMWColors.line)
                .frame(height: 1)
            Text(text.uppercased())
                .font(PMWFont.t3(.black))
                .tracking(1)
                .foregroundStyle(PMWColors.accent)
        }
        .frame(width: 52, height: 52)
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
