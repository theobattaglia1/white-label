import Foundation

// MARK: - Session model -------------------------------------------------------

/// A Supabase GoTrue session. Stored in the Keychain via PMWKeychain.
struct PMWAuthSession: Codable {
    struct User: Codable {
        let id: String
        let email: String?
    }

    let accessToken: String
    let refreshToken: String
    /// Wall-clock expiry. Computed from `expires_in` at sign-in / refresh time.
    let expiresAt: Date
    let user: User
}

// MARK: - Errors --------------------------------------------------------------

enum PMWAuthError: Error, LocalizedError {
    /// GoTrue returned a non-2xx response with a human-readable message.
    case serverError(String)
    /// The HTTP response body could not be decoded.
    case decodingError(Error)
    /// A network-level failure (no connectivity, DNS, etc.).
    case networkError(Error)
    /// The session is missing tokens or the server returned an unexpected shape.
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .serverError(let msg):   return msg
        case .decodingError:          return "Unexpected response from the server."
        case .networkError(let err):  return err.localizedDescription
        case .invalidResponse:        return "Invalid sign-in response."
        }
    }

    /// Human message suitable for display inside PMWSignInView.
    var humanMessage: String {
        switch self {
        case .serverError(let msg):
            // GoTrue commonly returns "Invalid login credentials" — pass through.
            return msg
        case .networkError:
            return "Network error. Check your connection and try again."
        case .decodingError, .invalidResponse:
            return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Wire types ----------------------------------------------------------

private struct GoTrueTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
    /// Unix epoch seconds. GoTrue includes this since v2; use it when present
    /// to avoid clock-skew-induced refresh storms.
    let expires_at: Double?
    let user: GoTrueUser?
}

private struct GoTrueUser: Decodable {
    let id: String
    let email: String?
}

private struct GoTrueError: Decodable {
    // GoTrue uses both "msg" and "error_description" depending on version.
    let msg: String?
    let error_description: String?
    let message: String?

    var human: String {
        msg ?? error_description ?? message ?? "Authentication failed."
    }
}

// MARK: - Client --------------------------------------------------------------

/// Hand-rolled Supabase GoTrue REST client using URLSession + async/await.
/// No SPM dependencies. Mirrors the three calls used by the web's auth.ts.
struct PMWAuthClient {
    static let shared = PMWAuthClient()

    private let base: URL
    private let anonKey: String
    private let session: URLSession

    private init() {
        base = URL(string: PMWConfig.supabaseURL)!
        anonKey = PMWConfig.supabaseAnonKey
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    // MARK: - Public API ------------------------------------------------------

    /// Sign in with email + password. Returns a PMWAuthSession on success.
    func signIn(email: String, password: String) async throws -> PMWAuthSession {
        let url = base.appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        let body: [String: String] = ["email": email, "password": password]
        let response: GoTrueTokenResponse = try await post(url: url, body: body)
        return try makeSession(from: response)
    }

    /// Refresh an existing session using its refresh token.
    func refresh(refreshToken: String) async throws -> PMWAuthSession {
        let url = base.appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        let body: [String: String] = ["refresh_token": refreshToken]
        let response: GoTrueTokenResponse = try await post(url: url, body: body)
        return try makeSession(from: response)
    }

    /// Sign out the current session server-side (best-effort; ignores network
    /// errors so a failed sign-out doesn't block the local clear).
    func signOut(accessToken: String) async {
        let url = base.appendingPathComponent("auth/v1/logout")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        _ = try? await session.data(for: request)
    }

    // MARK: - Internals -------------------------------------------------------

    private func post<T: Decodable>(url: URL, body: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw PMWAuthError.networkError(error)
        }

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: request)
            data = d
            guard let h = r as? HTTPURLResponse else { throw PMWAuthError.invalidResponse }
            httpResponse = h
        } catch let error as PMWAuthError {
            throw error
        } catch {
            throw PMWAuthError.networkError(error)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Attempt to parse GoTrue's error body.
            if let gtError = try? JSONDecoder().decode(GoTrueError.self, from: data) {
                throw PMWAuthError.serverError(gtError.human)
            }
            throw PMWAuthError.serverError("Authentication failed (\(httpResponse.statusCode)).")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PMWAuthError.decodingError(error)
        }
    }

    private func makeSession(from response: GoTrueTokenResponse) throws -> PMWAuthSession {
        guard let user = response.user else { throw PMWAuthError.invalidResponse }
        // Prefer the server-side Unix epoch timestamp to avoid clock-skew
        // refresh storms. Fall back to device-relative computation only when
        // the field is absent (older GoTrue deployments).
        let expiresAt: Date
        if let serverEpoch = response.expires_at {
            expiresAt = Date(timeIntervalSince1970: serverEpoch)
        } else {
            expiresAt = Date().addingTimeInterval(TimeInterval(response.expires_in))
        }
        return PMWAuthSession(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: expiresAt,
            user: PMWAuthSession.User(id: user.id, email: user.email)
        )
    }
}

// MARK: - URL helpers ---------------------------------------------------------

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
