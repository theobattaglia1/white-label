import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SignInView: View {
    var auth: PlaybackAuthSession
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var mode: Mode = .signIn

    enum Mode { case signIn, signUp }

    private var canSubmit: Bool {
        let nameOK = mode == .signIn || !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return email.contains("@") && password.count >= 6 && !auth.isLoading && nameOK
    }

    var body: some View {
        ZStack {
            PB.black.ignoresSafeArea()
            AmbientDotField(isPlaying: true, positionMs: 42_000)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                PlaybackWordmark(capSize: 24, fontSize: 26, isPlaying: true)
                    .frame(width: 168, height: 30, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text(mode == .signIn ? "Sign in" : "Create account")
                        .font(PB.display(42))
                        .foregroundStyle(PB.cream)
                    MonoLabel("Cloud library · private sharing", color: PB.pencil, size: 10, tracking: 1.6)
                }

                VStack(spacing: 12) {
                    if mode == .signUp {
                        field("Display name", text: $displayName, keyboard: .default, isSecure: false,
                              autocap: .words)
                    }
                    field("Email", text: $email, keyboard: .emailAddress, isSecure: false)
                    field("Password", text: $password, keyboard: .default, isSecure: true)
                }

                if let error = auth.errorMessage {
                    MonoLabel(error, color: PB.redline, size: 9, tracking: 1)
                }
                if auth.keychainSaveFailed {
                    MonoLabel("Signed in, but session may not persist on relaunch", color: PB.redline, size: 9, tracking: 1)
                }

                Button { submit() } label: {
                    Text(auth.isLoading ? "WORKING" : (mode == .signIn ? "SIGN IN" : "CREATE ACCOUNT"))
                        .font(PB.mono(11))
                        .tracking(1.6)
                        .foregroundStyle(PB.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(canSubmit ? PB.cream : PB.pencil))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        mode = mode == .signIn ? .signUp : .signIn
                    }
                } label: {
                    MonoLabel(mode == .signIn ? "Create a new account" : "I already have an account",
                              color: PB.cobalt,
                              size: 10,
                              tracking: 1.2)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 460, alignment: .leading)
        }
        .foregroundStyle(PB.cream)
    }

    @ViewBuilder
    private func field(
        _ label: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        isSecure: Bool,
        autocap: TextInputAutocapitalization = .never
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel(label, color: PB.pencil, size: 10, tracking: 2)
            Group {
                if isSecure {
                    SecureField(label, text: text)
                } else {
                    TextField(label, text: text)
                        .textInputAutocapitalization(autocap)
                        .keyboardType(keyboard)
                }
            }
            .font(PB.text(17))
            .foregroundStyle(PB.cream)
            .tint(PB.cobalt)
            .textContentType(isSecure ? .password : (keyboard == .emailAddress ? .emailAddress : .name))
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
        }
    }

    private func submit() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        Task {
            switch mode {
            case .signIn:
                await auth.signIn(email: email, password: password)
            case .signUp:
                await auth.signUp(email: email, password: password, displayName: displayName)
            }
        }
    }
}
