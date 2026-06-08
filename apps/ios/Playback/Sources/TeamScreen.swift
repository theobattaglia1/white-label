import SwiftUI

private let ROLES = ["engineer", "artist", "manager", "anr", "producer", "viewer"]

struct TeamScreen: View {
    @State private var members: [ServiceClient.APIMember] = []
    @State private var invites: [ServiceClient.APIInvite] = []
    @State private var loading = true
    @State private var error: String? = nil
    @State private var showInviteSheet = false
    @State private var sentBanner: String? = nil
    @State private var revoking: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                AppScreenHeader(title: "Team")

                if let sentBanner {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(PB.green)
                        Text("Invite sent to \(sentBanner)")
                            .font(PB.mono(12))
                            .foregroundStyle(PB.green)
                        Spacer()
                        Button { self.sentBanner = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11))
                                .foregroundStyle(PB.pencil)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PB.green.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PB.green.opacity(0.3), lineWidth: 1))
                }

                if let error {
                    Text(error)
                        .font(PB.mono(11))
                        .foregroundStyle(PB.redline)
                        .padding(.vertical, 4)
                }

                // Invite button
                Button {
                    showInviteSheet = true
                } label: {
                    Label("Invite someone", systemImage: "person.badge.plus")
                        .font(PB.dot(13))
                        .tracking(1.4)
                        .foregroundStyle(PB.cream)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PB.cobalt))
                }
                .buttonStyle(.plain)

                // Members
                teamSection("Members · \(members.count)") {
                    if loading {
                        HStack {
                            ProgressView().tint(PB.pencil)
                            Text("Loading…").font(PB.mono(11)).foregroundStyle(PB.pencil)
                        }
                        .padding(.vertical, 12)
                    } else if members.isEmpty {
                        MonoLabel("No members yet", color: PB.pencil, size: 11)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(members) { member in
                            memberRow(member)
                        }
                    }
                }

                // Pending invites
                if !invites.isEmpty {
                    teamSection("Pending · \(invites.count)") {
                        ForEach(invites) { invite in
                            inviteRow(invite)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(PB.pencil)
                    MonoLabel("Sign-ups are invite-only", color: PB.pencil, size: 9, tracking: 1.2)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background {
            PB.black.ignoresSafeArea()
        }
        .foregroundStyle(PB.cream)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $showInviteSheet) {
            InviteSheet { email, role, name in
                await handleInvite(email: email, role: role, name: name)
            }
        }
        .refreshable { await load() }
    }

    private func memberRow(_ member: ServiceClient.APIMember) -> some View {
        HStack(spacing: 12) {
            avatar(member.display_name, color: PB.cobalt)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.display_name)
                    .font(PB.text(14))
                    .foregroundStyle(PB.cream)
                HStack(spacing: 6) {
                    MonoLabel(member.role, color: PB.pencil, size: 9, tracking: 1.2)
                    if let num = member.member_number {
                        MonoLabel("· PB·\(String(format: "%03d", num))", color: PB.pencil, size: 9, tracking: 1.2)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 14)
        }
    }

    private func inviteRow(_ invite: ServiceClient.APIInvite) -> some View {
        HStack(spacing: 12) {
            avatar(invite.email, color: PB.pencil, pending: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(invite.display_name ?? invite.email)
                    .font(PB.text(14))
                    .foregroundStyle(PB.cream.opacity(0.6))
                HStack(spacing: 6) {
                    MonoLabel(invite.email, color: PB.pencil, size: 9, tracking: 0.8)
                    MonoLabel("· \(invite.role)", color: PB.pencil, size: 9, tracking: 1.2)
                }
            }
            Spacer()
            Button {
                guard revoking == nil else { return }
                Task { await revoke(invite) }
            } label: {
                Group {
                    if revoking == invite.invite_id {
                        ProgressView().tint(PB.pencil).scaleEffect(0.7)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PB.pencil)
                    }
                }
                .frame(width: 28, height: 28)
                .background(Circle().fill(PB.cream.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .disabled(revoking != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 14)
        }
    }

    private func avatar(_ name: String, color: Color, pending: Bool = false) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let label = initials.isEmpty ? name.prefix(2).uppercased() : initials
        return Circle()
            .fill(color.opacity(pending ? 0.15 : 0.22))
            .overlay(
                Text(String(label))
                    .font(PB.mono(10))
                    .foregroundStyle(pending ? PB.pencil : color)
            )
            .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private func teamSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
        }
    }

    private func load() async {
        loading = true
        error = nil
        async let m = ServiceClient.shared.members()
        async let i = ServiceClient.shared.listInvites()
        do {
            let (fetchedMembers, fetchedInvites) = try await (m, i)
            members = fetchedMembers
            invites = fetchedInvites
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func handleInvite(email: String, role: String, name: String) async {
        do {
            _ = try await ServiceClient.shared.sendInvite(
                email: email,
                role: role,
                displayName: name.isEmpty ? nil : name
            )
            await load()
            sentBanner = email
        } catch {
            self.error = "Invite failed: \(error.localizedDescription)"
        }
    }

    private func revoke(_ invite: ServiceClient.APIInvite) async {
        revoking = invite.invite_id
        do {
            try await ServiceClient.shared.revokeInvite(inviteID: invite.invite_id)
            await load()
        } catch {
            self.error = "Could not revoke: \(error.localizedDescription)"
        }
        revoking = nil
    }
}

// MARK: - Invite sheet

private struct InviteSheet: View {
    var onSend: (String, String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = "viewer"
    @State private var name = ""
    @State private var sending = false
    @State private var error: String? = nil
    @FocusState private var emailFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MonoLabel("Send invite", size: 11, tracking: 2)

                    VStack(alignment: .leading, spacing: 8) {
                        MonoLabel("Email", color: PB.pencil, size: 9, tracking: 1.6)
                        TextField("email@studio.com", text: $email)
                            .font(PB.text(15))
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($emailFocused)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(PB.panel))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                                emailFocused ? PB.cobalt : PB.cream.opacity(0.1), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MonoLabel("Name (optional)", color: PB.pencil, size: 9, tracking: 1.6)
                        TextField("Alex Rivera", text: $name)
                            .font(PB.text(15))
                            .textInputAutocapitalization(.words)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(PB.panel))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PB.cream.opacity(0.1), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MonoLabel("Role", color: PB.pencil, size: 9, tracking: 1.6)
                        VStack(spacing: 0) {
                            ForEach(ROLES, id: \.self) { r in
                                Button { role = r } label: {
                                    HStack {
                                        MonoLabel(r.capitalized, color: PB.cream, size: 12, tracking: 0.8)
                                        Spacer()
                                        if role == r {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(PB.cobalt)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if r != ROLES.last {
                                    Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 14)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12).fill(PB.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
                    }

                    if let error {
                        Text(error)
                            .font(PB.mono(11))
                            .foregroundStyle(PB.redline)
                    }

                    Text("They'll receive a Playback invite email with a one-tap sign-in link. Sign-up is invite-only.")
                        .font(PB.mono(10))
                        .tracking(0.4)
                        .foregroundStyle(PB.pencil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            .background(PB.black.ignoresSafeArea())
            .foregroundStyle(PB.cream)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(PB.text(15))
                        .foregroundStyle(PB.pencil)
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !sending, !email.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        sending = true
                        Task {
                            await onSend(email.trimmingCharacters(in: .whitespaces), role, name)
                            sending = false
                            dismiss()
                        }
                    } label: {
                        if sending {
                            ProgressView().tint(PB.cobalt)
                        } else {
                            Text("Send").font(PB.text(15)).foregroundStyle(PB.cobalt)
                        }
                    }
                    .disabled(sending || email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { emailFocused = true }
    }
}
