import SwiftUI
import LocalAuthentication

@main
struct PrivateMusicWorkspaceApp: App {
    /// Set when iOS hands us a `wl://r/<token>` deep link
    /// (also reachable via universal link if entitled later).
    @State private var recipientToken: String? = nil

    /// Shared session — observed here so the sign-in gate reacts to
    /// sign-in success / mid-session token-refresh failure.
    @StateObject private var session = PMWSession.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Gate composition:
                //   OUTER — PMWBiometricGate (Face ID / passcode)
                //   INNER — PMWSessionGate   (Supabase sign-in)
                // Both gates are only enforced when their respective flags are
                // on. The biometric gate has its own DEBUG-default-off logic.
                // The session gate only fires when WL_USE_REAL_AUTH=1.
                PMWBiometricGate {
                    PMWSessionGate(session: session) {
                        PMWRootView()
                    }
                }

                // Recipient surface slides up over the producer workspace
                // when we receive a share-link deep link. Intentionally
                // OUTSIDE the gate — share links must open freely.
                if let token = recipientToken {
                    PMWRecipientView(token: token)
                        .transition(.move(edge: .bottom))
                        .zIndex(2)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: recipientToken)
            .onOpenURL { url in
                handle(url: url)
            }
        }
    }

    /// Accepts:
    ///   wl://r/<token>            (custom scheme)
    ///   https://white-label.../shared/<token>  (universal links, future)
    private func handle(url: URL) {
        if url.scheme == "wl", url.host == "r" {
            recipientToken = url.lastPathComponent
            return
        }
        if url.scheme?.hasPrefix("http") == true,
           url.pathComponents.count >= 3,
           url.pathComponents[url.pathComponents.count - 2] == "shared" {
            recipientToken = url.lastPathComponent
        }
    }
}

/// Wraps the producer workspace in a Face ID / device-auth gate. After the
/// app has been backgrounded for more than `lockAfterSeconds`, foregrounding
/// requires biometric authentication before the workspace is revealed.
///
/// Recipient surfaces (`PMWRecipientView`) live outside this gate — share
/// links must open freely.
///
/// Producers can disable the gate via the `WL_DISABLE_LOCK=1` env var on
/// the run scheme (useful for demos / screenshots).
struct PMWBiometricGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var lastBackgroundedAt: Date?
    @State private var authError: String?

    /// 60 s grace window — quick context switches (text, AirPods control)
    /// don't re-prompt for Face ID; longer absence does.
    private let lockAfterSeconds: TimeInterval = 60

    var body: some View {
        ZStack {
            if unlocked || disabled {
                content()
            } else {
                lockScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: unlocked)
        .task {
            // First launch — try the gate immediately. If biometrics aren't
            // available or the user cancels, the lock screen stays up with
            // a Retry button.
            if !disabled { await authenticate() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lastBackgroundedAt = Date()
                unlocked = false
            case .active:
                guard !disabled else { unlocked = true; return }
                if let bg = lastBackgroundedAt,
                   Date().timeIntervalSince(bg) >= lockAfterSeconds {
                    unlocked = false
                    Task { await authenticate() }
                } else if lastBackgroundedAt == nil {
                    // First foreground — already triggered by .task
                }
            default: break
            }
        }
    }

    /// Gate behaviour:
    ///  - DEBUG builds default to OFF so daily Xcode runs / simulator sessions
    ///    don't hit the Face ID prompt on every relaunch. You can still
    ///    force-test the lock by setting `WL_FORCE_LOCK=1` on the scheme.
    ///  - Release builds default to ON. Set `WL_DISABLE_LOCK=1` to override.
    private var disabled: Bool {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if env["WL_FORCE_LOCK"] == "1" { return false }
        return true
        #else
        return env["WL_DISABLE_LOCK"] == "1"
        #endif
    }

    private var lockScreen: some View {
        ZStack {
            PMWColors.studioBlack.ignoresSafeArea()
            VStack(spacing: 22) {
                PMWWordmark(size: .lg)
                Text("Locked")
                    .font(PMWFont.mono(11, weight: .bold))
                    .kerning(1.8)
                    .foregroundStyle(PMWColors.pencilWarm)
                if let authError {
                    Text(authError)
                        .font(PMWFont.mono(11))
                        .foregroundStyle(PMWColors.redline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Button {
                    Task { await authenticate() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                            .font(.system(size: 16, weight: .semibold))
                        Text("UNLOCK")
                            .font(PMWFont.mono(12, weight: .bold))
                            .kerning(1.6)
                    }
                    .foregroundStyle(PMWColors.tapeOxide)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 2).stroke(PMWColors.tapeOxide, lineWidth: 1))
                }
                .accessibilityLabel("Unlock with Face ID")
            }
        }
    }

    private func authenticate() async {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use passcode"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics + no passcode configured — let the app in but
            // warn the user. Avoid a fatal lockout state on the simulator
            // or a fresh device.
            unlocked = true
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Reveal your private workspace."
            )
            if ok {
                authError = nil
                unlocked = true
            }
        } catch let err as LAError where err.code == .userCancel || err.code == .systemCancel {
            authError = nil
        } catch let err as LAError where err.code == .appCancel {
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }
}

// MARK: - Session gate --------------------------------------------------------

/// Sits INSIDE PMWBiometricGate. When `PMWConfig.useRealAuth` is false (the
/// default), this view is completely transparent — it renders `content()`
/// directly with zero overhead.
///
/// When the flag is true:
///   - If a valid (or refreshable) Keychain session exists → content appears.
///   - If not signed in → PMWSignInView is shown until sign-in succeeds.
///   - If a mid-session refresh fails → session clears → sign-in re-appears.
///
/// The flag-off path is structurally identical to the pre-auth codebase:
/// no sign-in screen, no token checks, dev/sample mode untouched.
struct PMWSessionGate<Content: View>: View {
    @ObservedObject var session: PMWSession
    @ViewBuilder var content: () -> Content

    var body: some View {
        if !PMWConfig.useRealAuth || session.isSignedIn {
            content()
        } else {
            PMWSignInView(session: session)
                .transition(.opacity)
        }
    }
}
