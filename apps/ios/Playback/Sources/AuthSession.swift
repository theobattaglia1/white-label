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
    case invalidResponse
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
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

    func signUp(email: String, password: String) async throws -> AuthSessionModel {
        let url = Config.supabaseURLURL.appendingPathComponent("auth/v1/signup")
        let response: TokenResponse = try await post(url: url, body: ["email": email, "password": password])
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                if let decoded = try? JSONDecoder().decode(GoTrueError.self, from: data) {
                    throw AuthError.server(decoded.human)
                }
                throw AuthError.server("Authentication failed (\(http.statusCode)).")
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
            keychainSaveFailed = !AuthKeychain.save(session)
            await refreshProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signUp(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let session = try await AuthClient.shared.signUp(email: email, password: password)
            current = session
            keychainSaveFailed = !AuthKeychain.save(session)
            await refreshProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signOut() async {
        if let token = current?.accessToken {
            await AuthClient.shared.signOut(accessToken: token)
        }
        current = nil
        profile = nil
        errorMessage = nil
        keychainSaveFailed = false
        AuthKeychain.delete()
    }

    func switchWorkspace(_ id: String) {
        activeWorkspaceID = id
        UserDefaults.standard.set(id, forKey: workspaceKey)
    }

    func refreshProfile() async {
        guard Config.useRealAuth, current != nil else { return }
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

    func validAccessToken() async -> String? {
        guard let session = current else { return nil }
        guard session.expiresAt.timeIntervalSinceNow <= 60 else { return session.accessToken }

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
            return refreshed.accessToken
        } catch {
            refreshTask = nil
            current = nil
            AuthKeychain.delete()
            return nil
        }
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
