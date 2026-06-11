import SwiftUI

/// Profile / You — identity and the customizations a music app usually carries.
struct ProfileView: View {
    var player: Player
    var store: WorkspaceStore
    var auth: PlaybackAuthSession
    @AppStorage("wl.reduceMotion") private var reduceMotion = false
    @AppStorage("wl.defaultAccess") private var defaultAccess = "Restricted"
    @State private var joinLinkURL: IdentifiableURL? = nil
    @State private var isGeneratingLink = false
    @State private var joinLinkError: String? = nil

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 28) {
                    AppScreenHeader(title: "Profile", isPlaying: player.isPlaying)

                    identityCard

                    section("Appearance") {
                        toggleRow("Reduce motion", $reduceMotion)
                    }
                    section("Sharing") {
                        menuRow("Default link access", $defaultAccess, ["Restricted", "Anyone with the link"])
                    }
                    if Config.useRemoteAPI {
                        inviteSection
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
                        section("Workspace") {
                            NavigationLink(destination: TeamScreen()) {
                                HStack {
                                    Text("Manage team").font(PB.text(15)).foregroundStyle(PB.cream)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12))
                                        .foregroundStyle(PB.pencil)
                                }
                                .padding(.horizontal, 15).padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if Config.useRealAuth {
                        Button { Task { await auth.signOut() } } label: {
                            Text("Sign out").font(PB.text(15)).foregroundStyle(PB.redline)
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                        }
                        .buttonStyle(.plain)
                    }

                    MonoLabel("Playback · v0.1", color: PB.pencil, size: 9, tracking: 1.4)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)
            .background {
                PB.black.ignoresSafeArea()
                AmbientPlayerBackdrop(player: player)
                    .allowsHitTesting(false).ignoresSafeArea()
            }
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .foregroundStyle(PB.cream)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel("Invite", color: PB.pencil, size: 10, tracking: 2)
            Button {
                generateInviteLink()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isGeneratingLink ? "ellipsis" : "link.badge.plus")
                        .font(.system(size: 15))
                        .foregroundStyle(PB.cobalt)
                        .frame(width: 22)
                    Text(isGeneratingLink ? "Generating link…" : "Generate invite link")
                        .font(PB.text(15))
                        .foregroundStyle(PB.cream)
                    Spacer()
                }
                .padding(.horizontal, 15).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isGeneratingLink)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))

            if let error = joinLinkError {
                MonoLabel(error, color: PB.redline, size: 9, tracking: 1)
            }

            MonoLabel("Anyone with the link can sign up and join your workspace.", color: PB.pencil.opacity(0.6), size: 9, tracking: 0.6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .shareSheet(item: $joinLinkURL) { wrapper in
            let message = "You've been invited to join me on Playback. Create your account here: \(wrapper.url.absoluteString)"
            return [message]
        }
    }

    private func generateInviteLink() {
        guard !isGeneratingLink else { return }
        joinLinkError = nil
        isGeneratingLink = true
        Task {
            do {
                let link = try await ServiceClient.shared.generateJoinLink()
                await MainActor.run {
                    isGeneratingLink = false
                    if let url = URL(string: link.url) {
                        joinLinkURL = IdentifiableURL(url)
                    }
                }
            } catch {
                await MainActor.run {
                    isGeneratingLink = false
                    joinLinkError = "Could not generate link. Try again."
                }
            }
        }
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
