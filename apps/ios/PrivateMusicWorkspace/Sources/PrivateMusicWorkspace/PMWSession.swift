import Foundation

/// Manages the current Supabase auth session. Backed by the Keychain.
///
/// Matches the existing ObservableObject/@Published pattern used by PMWStore
/// and PMWAudioEngine. Does NOT use @Observable (iOS 17+ macro) to stay
/// consistent with the codebase.
///
/// Thread safety: all mutations happen on the MainActor (via @MainActor
/// annotation and Task { @MainActor in ... } in the refresh path). Reads
/// from PMWAPIClient.send() are fine — they await on a background thread
/// and the property access is value-typed (String copy).
@MainActor
final class PMWSession: ObservableObject {
    /// The singleton used by PMWAPIClient. Populated by the app entry point.
    static let shared = PMWSession()

    @Published private(set) var current: PMWAuthSession?

    /// Set to true when a Keychain save failed so the UI can surface a
    /// "session may not persist" warning. Not an error the user is blocked on.
    @Published private(set) var keychainSaveFailed = false

    var isSignedIn: Bool { current != nil }

    // MARK: - Single-flight refresh -------------------------------------------

    /// In-progress refresh task. All concurrent callers in validAccessToken()
    /// share this single Task rather than each firing their own refresh, which
    /// would burn the GoTrue single-use refresh token and sign the user out.
    /// Safe because PMWSession is @MainActor — creation/clearance are atomic.
    private var refreshTask: Task<PMWAuthSession, Error>?

    // MARK: - Init ------------------------------------------------------------

    private init() {
        current = PMWKeychain.load()
    }

    // MARK: - Sign in / out ---------------------------------------------------

    /// Sign in with email + password. Updates `current` and persists to Keychain.
    /// Throws `PMWAuthError` on failure.
    func signIn(email: String, password: String) async throws {
        let session = try await PMWAuthClient.shared.signIn(email: email, password: password)
        current = session
        let saved = PMWKeychain.save(session)
        keychainSaveFailed = !saved
    }

    /// Sign out: clears the local session and best-effort invalidates server-side.
    func signOut() async {
        if let token = current?.accessToken {
            await PMWAuthClient.shared.signOut(accessToken: token)
        }
        current = nil
        keychainSaveFailed = false
        PMWKeychain.delete()
    }

    // MARK: - Token access (used by PMWAPIClient) ------------------------------

    /// Returns a valid access token, transparently refreshing when within 60 s
    /// of expiry. Returns nil when:
    ///   - No session exists (not signed in).
    ///   - The refresh attempt fails with an auth rejection (session cleared;
    ///     caller should re-present the sign-in gate).
    ///
    /// Network errors do NOT clear the session — the existing (possibly-expired)
    /// token is returned so the app continues to function offline. This is safe
    /// while server-side JWT enforcement is deferred.
    ///
    /// Concurrent callers near expiry share a single refresh Task to avoid
    /// burning the GoTrue single-use refresh token.
    func validAccessToken() async -> String? {
        guard let session = current else { return nil }

        let secondsUntilExpiry = session.expiresAt.timeIntervalSinceNow
        guard secondsUntilExpiry <= 60 else {
            // Token is still fresh.
            return session.accessToken
        }

        // Needs refresh. If a refresh is already in flight, await it; otherwise
        // start one. Both paths share the same Task — only one network call goes
        // out regardless of how many callers land here simultaneously.
        let task: Task<PMWAuthSession, Error>
        if let existing = refreshTask {
            task = existing
        } else {
            let refreshToken = session.refreshToken
            let newTask = Task<PMWAuthSession, Error> {
                try await PMWAuthClient.shared.refresh(refreshToken: refreshToken)
            }
            refreshTask = newTask
            task = newTask
        }

        do {
            let refreshed = try await task.value
            // Clear the in-flight task. On @MainActor, the resume from `await`
            // and the nil assignment are serialized — no other caller can slot
            // in between, so unconditional clear is correct.
            refreshTask = nil
            current = refreshed
            let saved = PMWKeychain.save(refreshed)
            keychainSaveFailed = !saved
            return refreshed.accessToken
        } catch {
            refreshTask = nil

            // Distinguish network failures from auth rejections.
            // On a network error: keep the session alive so the app works
            // offline (server enforcement is deferred; a stale token is safe
            // to return to the API client for now).
            // On an auth rejection (bad/expired refresh token → 400/401):
            // clear the session so the sign-in gate re-appears.
            switch error {
            case PMWAuthError.networkError:
                // Offline or unreachable — keep session, return stale token.
                return current?.accessToken
            case is URLError:
                // URLSession-level connectivity failure — same treatment.
                return current?.accessToken
            default:
                // Auth-layer rejection (serverError, invalidResponse, etc.)
                // — clear session so the user is prompted to sign in again.
                current = nil
                PMWKeychain.delete()
                return nil
            }
        }
    }
}
