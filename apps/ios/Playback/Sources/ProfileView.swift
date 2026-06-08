import SwiftUI

/// Profile / You — identity and the customizations a music app usually carries.
struct ProfileView: View {
    var player: Player
    var store: WorkspaceStore
    var auth: PlaybackAuthSession
    @AppStorage("wl.reduceMotion") private var reduceMotion = false
    @AppStorage("wl.loudnessMatch") private var loudnessMatch = true
    @AppStorage("wl.autoplayNext") private var autoplayNext = true
    @AppStorage("wl.notifications") private var notifications = true
    @AppStorage("wl.defaultAccess") private var defaultAccess = "Restricted"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                AppScreenHeader(title: "Profile", isPlaying: player.isPlaying)

                identityCard

                section("Playback") {
                    toggleRow("Loudness match", $loudnessMatch)
                    toggleRow("Autoplay next", $autoplayNext)
                }
                section("Appearance") {
                    toggleRow("Reduce motion", $reduceMotion)
                }
                section("Sharing") {
                    menuRow("Default link access", $defaultAccess, ["Restricted", "Anyone with the link"])
                }
                section("Library") {
                    valueRow("Mode", Config.useRemoteAPI ? "Cloud + offline" : "Offline-only")
                    valueRow("Cloud library", cloudLabel)
                    valueRow("Status", statusLabel)
                    valueRow("Last save", lastSaveLabel)
                }
                if Config.useRealAuth {
                    section("Account") {
                        valueRow("Email", auth.email)
                        workspaceRow
                    }
                }
                section("Notifications") {
                    toggleRow("Push notifications", $notifications)
                }

                Button { Task { await auth.signOut() } } label: {
                    Text("Sign out").font(PB.text(15)).foregroundStyle(PB.redline)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                }
                .buttonStyle(.plain)

                MonoLabel("Playback · v0.1", color: PB.pencil, size: 9, tracking: 1.4)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background {
            PB.black.ignoresSafeArea()
            AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
                .allowsHitTesting(false).ignoresSafeArea()
        }
        .foregroundStyle(PB.cream)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var lastSaveLabel: String {
        guard let lastSavedAt = store.lastSavedAt else { return "Ready" }
        return lastSavedAt.formatted(.dateTime.hour().minute())
    }

    private var cloudLabel: String {
        guard Config.useRemoteAPI else { return "Off" }
        switch store.syncState {
        case .synced: return "Connected"
        case .syncing: return "Connecting"
        case .offline: return store.isUsingServiceLibrary ? "Offline copy" : "Unavailable"
        default: return store.isUsingServiceLibrary ? "Connected" : "Ready"
        }
    }

    private var statusLabel: String {
        store.syncMessage.isEmpty ? store.syncState.rawValue : store.syncMessage
    }

    private var identityCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(LinearGradient(colors: [PB.cobalt, Color(hex: 0x8597EE)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(Text("TB").font(PB.display(20)).foregroundStyle(PB.cream))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName).font(PB.display(20)).foregroundStyle(PB.cream)
                MonoLabel(identityDetail, color: PB.pencil, size: 10, tracking: 1.2)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
    }

    private var displayName: String {
        auth.profile?.user.display_name.isEmpty == false ? auth.profile!.user.display_name : "Playback"
    }

    private var identityDetail: String {
        if Config.useRealAuth {
            return "\(auth.activeWorkspaceName) · \(activeRole)"
        }
        return "All My Friends Inc · Owner"
    }

    private var activeRole: String {
        auth.workspaceOptions.first(where: { $0.id == auth.activeWorkspaceID })?.role ?? "Member"
    }

    private var workspaceRow: some View {
        HStack {
            Text("Workspace").font(PB.text(15)).foregroundStyle(PB.cream)
            Spacer()
            Menu {
                ForEach(auth.workspaceOptions, id: \.id) { option in
                    Button {
                        auth.switchWorkspace(option.id)
                    } label: {
                        Label(option.name, systemImage: option.id == auth.activeWorkspaceID ? "checkmark" : "music.note")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    MonoLabel(auth.activeWorkspaceName, color: PB.pencil, size: 10, tracking: 0.8)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(PB.pencil)
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 15) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
        }
    }

    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(label).font(PB.text(15)).foregroundStyle(PB.cream)
        }
        .tint(PB.cobalt)
        .padding(.horizontal, 15).padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 15) }
    }

    private func menuRow(_ label: String, _ binding: Binding<String>, _ options: [String]) -> some View {
        HStack {
            Text(label).font(PB.text(15)).foregroundStyle(PB.cream)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { o in Button(o) { binding.wrappedValue = o } }
            } label: {
                HStack(spacing: 5) {
                    MonoLabel(binding.wrappedValue, color: PB.pencil, size: 10, tracking: 0.8)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(PB.pencil)
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(PB.text(15)).foregroundStyle(PB.cream)
            Spacer()
            MonoLabel(value, color: PB.pencil, size: 10, tracking: 0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 15) }
    }
}
