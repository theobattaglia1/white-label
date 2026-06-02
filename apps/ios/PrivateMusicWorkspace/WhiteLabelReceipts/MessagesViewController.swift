import Combine
import Messages
import SwiftUI

/// WHITE LABEL · iMessage Extension entry point.
///
/// This is what gets embedded INSIDE iMessage when a recipient taps the
/// app drawer or opens a Receipt. Renders a SwiftUI hierarchy inside the
/// MSMessagesAppViewController canvas. Two presentation modes:
/// `compact` (220pt tall, the keyboard-area strip) and `expanded`
/// (~414pt, the full-canvas overlay).
///
/// The flow:
///  1. Sender (producer) composes a song with `composeReceipt(for:)`,
///     which creates an MSMessage whose URL encodes the WL share token.
///  2. Recipient sees the receipt bubble; tapping opens the app strip.
///  3. In compact mode → big cover + Play / Approve / Open in app.
///  4. In expanded mode → full transport, notes feed, composer.
///
/// Xcode setup is documented in `iOS_HANDOFF.md` — search "iMessage".
final class MessagesViewController: MSMessagesAppViewController {
    private var hostingController: UIHostingController<ReceiptHost>?
    @MainActor private let model = ReceiptModel()

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        Task { @MainActor in
            if let url = conversation.selectedMessage?.url {
                model.handleIncomingURL(url)
            }
            present(for: presentationStyle)
        }
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        present(for: presentationStyle)
    }

    @MainActor
    private func present(for style: MSMessagesAppPresentationStyle) {
        let host = ReceiptHost(model: model,
                               isExpanded: style == .expanded,
                               onRequestExpanded: { [weak self] in self?.requestPresentationStyle(.expanded) },
                               onSendReply: { [weak self] body, ts in
                                   self?.sendReply(body: body, timestampMS: ts)
                               },
                               onApprove: { [weak self] in
                                   self?.sendApproval()
                               })
        if let hostingController {
            hostingController.rootView = host
        } else {
            let controller = UIHostingController(rootView: host)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(controller); controller.didMove(toParent: self)
            view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            hostingController = controller
        }
    }

    @MainActor
    private func sendReply(body: String, timestampMS: Int) {
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty,
              let token = model.token else { return }
        Task {
            // Best-effort POST to /notes via the same API. Failure leaves
            // the note unsent locally; the recipient can retry.
            do {
                _ = try await WLReceiptAPI.shared.postNote(
                    token: token,
                    body: body,
                    timestampMS: timestampMS
                )
            } catch {
                // Surface to user via model state
                self.model.lastError = "Couldn't sync note: \(error.localizedDescription)"
                return
            }
            self.model.appendLocalNote(body: body, timestampMS: timestampMS, author: "Liv R.")
            self.requestPresentationStyle(.compact)
        }
    }

    @MainActor
    private func sendApproval() {
        guard model.token != nil, let versionID = model.currentVersionID else { return }
        Task {
            do {
                _ = try await WLReceiptAPI.shared.approve(versionID: versionID)
                self.model.markApproved()
            } catch {
                self.model.lastError = "Couldn't approve: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Model ------------------------------------------------------

@MainActor
final class ReceiptModel: ObservableObject {
    @Published var token: String?
    @Published var songTitle: String = "—"
    @Published var artist: String = ""
    @Published var versionLabel: String = ""
    @Published var versionNumber: Int = 1
    @Published var currentVersionID: String?
    @Published var durationMS: Int = 0
    @Published var positionMS: Int = 0
    @Published var notes: [ReceiptNote] = []
    @Published var isApproved: Bool = false
    @Published var lastError: String?

    struct ReceiptNote: Identifiable {
        let id = UUID().uuidString
        var author: String
        var body: String
        var timestampMS: Int?
    }

    /// Decode the URL the sender's app encoded: wl.fm/r/<token> or
    /// wl://r/<token>. The query may carry additional hints (title etc.)
    func handleIncomingURL(_ url: URL) {
        let parts = url.path.split(separator: "/")
        if parts.count >= 2, parts[0] == "r" {
            token = String(parts[1])
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                switch item.name {
                case "title":   songTitle = item.value ?? songTitle
                case "artist":  artist = item.value ?? artist
                case "label":   versionLabel = item.value ?? versionLabel
                case "version": versionNumber = Int(item.value ?? "1") ?? 1
                case "ms":      durationMS = Int(item.value ?? "0") ?? 0
                case "vid":     currentVersionID = item.value
                default: break
                }
            }
        }
        // Best-effort fetch of fresh data + notes from API
        guard let token else { return }
        Task {
            do {
                let payload = try await WLReceiptAPI.shared.shared(token: token)
                if let song = payload.songs.first {
                    songTitle = song.title
                    artist = song.artist_display_name ?? artist
                }
                if let current = payload.versions.first(where: { $0.is_current }) ?? payload.versions.last {
                    versionLabel = current.version_label ?? "v\(current.version_number)"
                    versionNumber = current.version_number
                    currentVersionID = current.version_id
                    isApproved = current.is_approved
                }
            } catch {
                lastError = "Couldn't refresh: \(error.localizedDescription)"
            }
        }
    }

    func appendLocalNote(body: String, timestampMS: Int, author: String) {
        notes.insert(.init(author: author, body: body, timestampMS: timestampMS), at: 0)
    }

    func markApproved() {
        isApproved = true
    }
}

// MARK: - SwiftUI host ----------------------------------------------

struct ReceiptHost: View {
    @ObservedObject var model: ReceiptModel
    let isExpanded: Bool
    let onRequestExpanded: () -> Void
    let onSendReply: (String, Int) -> Void
    let onApprove: () -> Void

    @State private var noteBody = ""

    var body: some View {
        ZStack {
            WLColors.sleeveCream.ignoresSafeArea()
            if isExpanded { expanded } else { compact }
        }
    }

    // ---- COMPACT (~220pt) -----------------------------------------

    private var compact: some View {
        HStack(spacing: 12) {
            cover(size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.songTitle)
                    .font(.system(size: 20, weight: .heavy, design: .default).width(.condensed))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text("\(model.artist) · \(model.versionLabel)")
                    .font(.system(size: 11, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.black.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(action: onRequestExpanded) {
                        Label("Open", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.85, green: 0.16, blue: 0.11)))
                    }
                    Button(action: onApprove) {
                        Text(model.isApproved ? "✓ Approved" : "Approve")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black, lineWidth: 1))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // ---- EXPANDED (~414pt) ----------------------------------------

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover(size: 110)
                .padding(.top, 16)

            Text(model.songTitle)
                .font(.system(size: 28, weight: .heavy, design: .default).width(.condensed))
                .foregroundStyle(.black)
                .padding(.top, 12)

            Text("\(model.artist) · \(model.versionLabel)")
                .font(.system(size: 12, design: .monospaced).weight(.semibold))
                .foregroundStyle(.black.opacity(0.6))

            HStack {
                Button(action: onApprove) {
                    Text(model.isApproved ? "✓ Approved" : "Approve master")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 2).fill(.black))
                }
                Button { /* open in app */ } label: {
                    Text("Open in WL")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black, lineWidth: 1))
                }
            }
            .padding(.top, 12)

            Divider().padding(.vertical, 14)

            Text("ADD A NOTE · @ \(formatMs(model.positionMS))")
                .font(.system(size: 10, design: .monospaced).weight(.semibold))
                .kerning(1.6)
                .foregroundStyle(.black.opacity(0.6))
            HStack {
                TextField("Note for the producer…", text: $noteBody, axis: .horizontal)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.2), lineWidth: 1))
                    )
                Button {
                    onSendReply(noteBody, model.positionMS)
                    noteBody = ""
                } label: {
                    Text("Send")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 2).fill(.black))
                }
            }

            if !model.notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.notes) { note in
                            VStack(alignment: .leading) {
                                Text(note.author)
                                    .font(.system(size: 11, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.black.opacity(0.6))
                                Text(note.body)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.black)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .padding(.top, 8)
            }

            if let err = model.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red).padding(.top, 8)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func cover(size: CGFloat) -> some View {
        LinearGradient(
            colors: [
                Color(red: 0.17, green: 0.16, blue: 0.14),
                Color(red: 0.37, green: 0.34, blue: 0.28),
                Color(red: 0.66, green: 0.62, blue: 0.55),
                Color(red: 0.84, green: 0.79, blue: 0.65),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .frame(width: size, height: size)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 2) {
                Text("WL").font(.system(size: size * 0.18, weight: .black, design: .default).width(.condensed)).foregroundStyle(.white)
                Rectangle().fill(Color(red: 0.85, green: 0.16, blue: 0.11)).frame(width: size * 0.07, height: size * 0.03)
                    .padding(.top, size * 0.1)
            }
            .padding(.leading, 6).padding(.bottom, 4)
            .blendMode(.difference)
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

// MARK: - Tiny color set (the extension can't import PMW main app) ----

enum WLColors {
    static let sleeveCream = Color(red: 0.949, green: 0.929, blue: 0.886)
    static let redline = Color(red: 0.85, green: 0.16, blue: 0.11)
}
