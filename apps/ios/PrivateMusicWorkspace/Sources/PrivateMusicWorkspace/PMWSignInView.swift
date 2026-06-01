import SwiftUI

/// Email + password sign-in screen presented after the biometric gate when
/// `PMWConfig.useRealAuth` is true. Matches the lock-screen aesthetic:
/// studioBlack background, tapeOxide text, mono caps, capsule fields,
/// the existing PMWWordmark + PMWChromeButtonStyle.
struct PMWSignInView: View {
    @ObservedObject var session: PMWSession

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password }

    var body: some View {
        ZStack {
            PMWColors.studioBlack.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 72)

                    PMWWordmark(size: .lg)
                        .padding(.bottom, 12)

                    Text("SIGN IN")
                        .font(PMWFont.mono(11, weight: .bold))
                        .kerning(2.2)
                        .foregroundStyle(PMWColors.pencilWarm)
                        .padding(.bottom, 48)

                    // Fields
                    VStack(spacing: 12) {
                        fieldRow(
                            placeholder: "Email",
                            text: $email,
                            field: .email,
                            isSecure: false
                        )
                        fieldRow(
                            placeholder: "Password",
                            text: $password,
                            field: .password,
                            isSecure: true
                        )
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)

                    // Error
                    if let errorMessage {
                        Text(errorMessage)
                            .font(PMWFont.sans(13))
                            .foregroundStyle(PMWColors.redline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 20)
                            .transition(.opacity)
                    }

                    // Sign in button
                    Button {
                        Task { await attemptSignIn() }
                    } label: {
                        ZStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(PMWColors.studioBlack)
                                    .scaleEffect(0.9)
                            } else {
                                Text("SIGN IN")
                                    .font(PMWFont.mono(13, weight: .bold))
                                    .kerning(1.6)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PMWChromeButtonStyle(variant: .accent))
                    .padding(.horizontal, 32)
                    .disabled(isLoading || email.isEmpty || password.isEmpty)

                    Spacer(minLength: 60)
                }
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.18), value: errorMessage)
        .onSubmit {
            switch focusedField {
            case .email:
                focusedField = .password
            case .password:
                Task { await attemptSignIn() }
            case nil:
                break
            }
        }
    }

    // MARK: - Field builder ---------------------------------------------------

    @ViewBuilder
    private func fieldRow(
        placeholder: String,
        text: Binding<String>,
        field: Field,
        isSecure: Bool
    ) -> some View {
        ZStack(alignment: .leading) {
            // Background capsule — matches the lock-screen button outline style
            // but filled so it reads as an input well.
            Capsule()
                .fill(PMWColors.studioPanel)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            focusedField == field
                                ? PMWColors.tapeOxide.opacity(0.5)
                                : PMWColors.studioHairline,
                            lineWidth: 1
                        )
                )

            if isSecure {
                SecureField("", text: text, prompt:
                    Text(placeholder)
                        .foregroundStyle(PMWColors.pencilWarm)
                        .font(PMWFont.sans(15))
                )
                .focused($focusedField, equals: field)
                .textContentType(.password)
                .autocorrectionDisabled()
                .foregroundStyle(PMWColors.tapeOxide)
                .font(PMWFont.sans(15))
                .padding(.horizontal, 20)
            } else {
                TextField("", text: text, prompt:
                    Text(placeholder)
                        .foregroundStyle(PMWColors.pencilWarm)
                        .font(PMWFont.sans(15))
                )
                .focused($focusedField, equals: field)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(PMWColors.tapeOxide)
                .font(PMWFont.sans(15))
                .padding(.horizontal, 20)
            }
        }
        .frame(height: 50)
        .accessibilityLabel(placeholder)
    }

    // MARK: - Auth action -----------------------------------------------------

    private func attemptSignIn() async {
        guard !isLoading else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        focusedField = nil

        do {
            try await session.signIn(email: trimmedEmail, password: password)
            // On success, PMWSession.isSignedIn flips to true — the gate in
            // PrivateMusicWorkspaceApp observes this and dismisses this view.
        } catch let authError as PMWAuthError {
            errorMessage = authError.humanMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }

        isLoading = false
    }
}
