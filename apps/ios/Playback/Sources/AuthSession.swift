import Foundation
import Observation
import Security

struct AuthSessionModel: Codable {
    struct User: Codable, Hashable {
        let id: String
        let email: String?
    }

    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let user: User
}

enum AuthError: Error, LocalizedError {
    case server(String)
    /// GoTrue definitively rejected the credentials / refresh token (4xx).
    /// Unlike .server (outage / 5xx) this is NOT transient: retrying with the
    /// same token can never succeed, so the session must be surfaced as dead.
    case sessionInvalid(String)
    case invalidResponse
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .sessionInvalid(let message): return message
        case .invalidResponse: return "Authentication failed. Please try again."
        case .network(let error): return error.localizedDescription
        }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
    let expires_at: Double?
    let user: TokenUser?
}

private struct TokenUser: Decodable {
    let id: String
    let email: String?
}

private struct GoTrueError: Decodable {
    let msg: String?
    let error_description: String?
    let message: String?

    var human: String {
        msg ?? error_description ?? message ?? "Authentication failed."
    }
}

struct AuthClient {
    static let shared = AuthClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func signIn(email: String, password: String) async throws -> AuthSessionModel {
        let url = Config.supabaseURLURL
            .appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        let response: TokenResponse = try await post(url: url, body: ["email": email, "password": password])
        return try makeSession(from: response)
    }

    func signUp(email: String, password: String, displayName: String = "") async throws -> AuthSessionModel {
        let url = Config.supabaseURLURL.appendingPathComponent("auth/v1/signup")
        var body: [String: Any] = ["email": email, "password": password]
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["data"] = ["display_name": trimmed] }
        let response: TokenResponse = try await postAny(url: url, body: body)
        return try makeSession(from: response)
    }

    func refresh(refreshToken: String) async throws -> AuthSessionModel {
        let url = Config.supabaseURLURL
            .appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        let response: TokenResponse = try await post(url: url, body: ["refresh_token": refreshToken])
        return try makeSession(from: response)
    }

    func signOut(accessToken: String) async {
        var request = URLRequest(url: Config.supabaseURLURL.appendingPathComponent("auth/v1/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.httpBody = Data("{}".utf8)
        _ = try? await session.data(for: request)
    }

    private func post<T: Decodable>(url: URL, body: [String: String]) async throws -> T {
        try await postAny(url: url, body: body)
    }

    private func postAny<T: Decodable>(url: URL, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(GoTrueError.self, from: data))?.human
                    ?? "Authentication failed (\(http.statusCode))."
                // 4xx = the token/credentials themselves were rejected (e.g.
                // "Invalid Refresh Token: Already Used") — permanently dead.
                // 5xx / timeouts = GoTrue outage — transient, keep the session.
                if (400...499).contains(http.statusCode) {
                    throw AuthError.sessionInvalid(message)
                }
                throw AuthError.server(message)
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.network(error)
        }
    }

    private func makeSession(from response: TokenResponse) throws -> AuthSessionModel {
        guard let user = response.user else { throw AuthError.invalidResponse }
        let expiresAt = response.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(TimeInterval(response.expires_in))
        return AuthSessionModel(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: expiresAt,
            user: AuthSessionModel.User(id: user.id, email: user.email)
        )
    }
}

@Observable
@MainActor
final class PlaybackAuthSession {
    static let shared = PlaybackAuthSession()

    var current: AuthSessionModel?
    var profile: ServiceClient.MePayload?
    var activeWorkspaceID: String
    var isLoading = false
    var errorMessage: String?
    var keychainSaveFailed = false
    /// True when the session died because GoTrue rejected our refresh token —
    /// the honest "SESSION EXPIRED — SIGN IN AGAIN" state. Never set for
    /// transient failures (network blips, GoTrue outages), which keep the
    /// session and retry later. Cleared by the next successful sign-in.
    var sessionExpired = false

    @ObservationIgnored private var refreshTask: Task<AuthSessionModel, Error>?
    @ObservationIgnored private let workspaceKey = "wl.activeWorkspaceID.v1"

    var isSignedIn: Bool { current != nil }
    var email: String { current?.user.email ?? profile?.user.email ?? "Signed in" }
    var workspaceOptions: [(id: String, name: String, role: String)] {
        guard let profile else { return [] }
        return profile.memberships.compactMap { membership in
            guard let workspace = profile.workspaces.first(where: { $0.workspace_id == membership.workspace_id }) else { return nil }
            return (workspace.workspace_id, workspace.name, membership.role)
        }
    }
    var activeWorkspaceName: String {
        workspaceOptions.first(where: { $0.id == activeWorkspaceID })?.name ?? "Workspace"
    }

    private init() {
        current = AuthKeychain.load()
        activeWorkspaceID = UserDefaults.standard.string(forKey: workspaceKey) ?? Config.defaultWorkspaceID
    }

    func bootstrap() async {
        guard Config.useRealAuth, current != nil else { return }
        await refreshProfile()
    }

    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await AuthClient.shared.signIn(email: email, password: password)
            current = session
            sessionExpired = false
            keychainSaveFailed = !AuthKeychain.save(session)
            await refreshProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signUp(email: String, password: String, displayName: String = "") async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await AuthClient.shared.signUp(email: email, password: password, displayName: displayName)
            current = session
            sessionExpired = false
            keychainSaveFailed = !AuthKeychain.save(session)
            await refreshProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signOut() async {
        // Clear local state immediately so the UI reacts at once.
        // Token revocation is best-effort and must not block the user.
        let token = current?.accessToken
        current = nil
        profile = nil
        errorMessage = nil
        keychainSaveFailed = false
        sessionExpired = false
        AuthKeychain.delete()
        if let token {
            Task { await AuthClient.shared.signOut(accessToken: token) }
        }
    }

    func switchWorkspace(_ id: String) {
        activeWorkspaceID = id
        UserDefaults.standard.set(id, forKey: workspaceKey)
    }

    func refreshProfile() async {
        // Run whenever the remote API is reachable — not just in real-auth mode.
        // In dev mode (useRealAuth=false) this populates member_number for the
        // PB·001 badge via the x-user-id fallback on GET /me.
        guard Config.useRemoteAPI else { return }
        if Config.useRealAuth { guard current != nil else { return } }
        do {
            let next = try await ServiceClient.shared.me()
            profile = next
            if !workspaceOptions.contains(where: { $0.id == activeWorkspaceID }),
               let first = workspaceOptions.first {
                switchWorkspace(first.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Proactive margin: refresh this many seconds before the token expires
    /// so a request never leaves the device with a token about to lapse.
    @ObservationIgnored private let expiryMargin: TimeInterval = 120

    /// Proactive path — used by every ServiceClient request. Returns the
    /// current access token, refreshing it first when it is near expiry.
    func validAccessToken() async -> String? {
        guard let session = current else { return nil }
        if session.expiresAt.timeIntervalSinceNow > expiryMargin { return session.accessToken }
        return await refreshedAccessToken(from: session)
    }

    /// Reactive path — the server answered 401 to `rejectedToken` even though
    /// the client believed it was fresh (revoked session, key rotation, clock
    /// skew). Refresh once and hand back a new token so the caller can retry.
    /// If a concurrent caller already refreshed, returns the newer token
    /// without spending another refresh.
    func accessTokenAfterRejection(of rejectedToken: String) async -> String? {
        guard let session = current else { return nil }
        if session.accessToken != rejectedToken { return session.accessToken }
        return await refreshedAccessToken(from: session)
    }

    /// Single-flight refresh. Concurrent callers (library refresh fan-out +
    /// upload queue) await one shared task — Supabase refresh tokens are
    /// single-use, so issuing two refreshes with the same token would kill
    /// the session.
    private func refreshedAccessToken(from session: AuthSessionModel) async -> String? {
        let task: Task<AuthSessionModel, Error>
        if let refreshTask {
            task = refreshTask
        } else {
            let refreshToken = session.refreshToken
            let next = Task<AuthSessionModel, Error> {
                try await AuthClient.shared.refresh(refreshToken: refreshToken)
            }
            refreshTask = next
            task = next
        }

        do {
            let refreshed = try await task.value
            refreshTask = nil
            current = refreshed
            keychainSaveFailed = !AuthKeychain.save(refreshed)
            sessionExpired = false
            return refreshed.accessToken
        } catch {
            refreshTask = nil
            if case AuthError.sessionInvalid = error {
                // GoTrue rejected the refresh token itself — the session is
                // permanently dead. Surface the honest expired state.
                expireSession()
            }
            // Anything else (network blip, GoTrue 5xx/timeout) is transient:
            // KEEP the session and let a later call retry the refresh.
            return nil
        }
    }

    /// The session is unrecoverable: clear it and flag the honest
    /// "session expired — sign in again" state (RootView swaps to SignInView).
    private func expireSession() {
        current = nil
        profile = nil
        AuthKeychain.delete()
        sessionExpired = true
    }
}

enum AuthKeychain {
    private static let service = "playback-auth"
    private static let account = "session"

    @discardableResult
    static func save(_ session: AuthSessionModel) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        delete()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> AuthSessionModel? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let session = try? JSONDecoder().decode(AuthSessionModel.self, from: data)
        else { return nil }
        return session
    }

    static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Config {
    static var supabaseURLURL: URL { URL(string: supabaseURL)! }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
