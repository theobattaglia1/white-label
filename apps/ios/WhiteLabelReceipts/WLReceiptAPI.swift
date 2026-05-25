import Foundation

/// Lightweight API client for the iMessage extension. Mirrors only the
/// endpoints the extension needs (shared payload, post note, approve).
/// Independent of the main app's PMWAPIClient so the extension target
/// doesn't need to compile the whole PMW source tree.
struct WLReceiptAPI {
    static let shared = WLReceiptAPI()

    /// Production: replace with your Render URL.
    /// Process env var `WL_API_BASE_URL` overrides for dev.
    private var baseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["WL_API_BASE_URL"],
           let url = URL(string: raw) { return url }
        return URL(string: "https://white-label-api.onrender.com")!
    }

    struct Envelope<T: Decodable>: Decodable { let data: T?; let error: String? }

    struct SharedPayload: Decodable {
        let songs: [Song]
        let versions: [Version]
        struct Song: Decodable {
            let song_id: String
            let title: String
            let artist_display_name: String?
        }
        struct Version: Decodable {
            let version_id: String
            let song_id: String
            let version_number: Int
            let version_label: String?
            let is_current: Bool
            let is_approved: Bool
        }
    }

    struct NoteResponse: Decodable {
        let note_id: String
    }

    struct ApprovalResponse: Decodable {
        let approval_id: String
    }

    // MARK: - calls

    func shared(token: String) async throws -> SharedPayload {
        try await send(method: "GET", path: "/shared/\(token)", body: nil, as: SharedPayload.self)
    }

    func postNote(token: String, body: String, timestampMS: Int) async throws -> NoteResponse {
        // Recipient flow: derive songID/versionID from /shared, then POST
        let shared = try await self.shared(token: token)
        guard let song = shared.songs.first,
              let v = shared.versions.first(where: { $0.is_current }) ?? shared.versions.last
        else {
            throw NSError(domain: "WL", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Empty receipt"])
        }
        return try await send(method: "POST", path: "/notes", body: [
            "song_id": song.song_id,
            "anchor_version_id": v.version_id,
            "body": body,
            "timestamp_start_ms": timestampMS,
            "scope": "song",
            "visibility": "everyone",
            "author_guest_label": "iMessage listener"
        ], as: NoteResponse.self)
    }

    func approve(versionID: String) async throws -> ApprovalResponse {
        try await send(method: "POST",
                       path: "/versions/\(versionID)/approvals",
                       body: ["state": "approved"],
                       as: ApprovalResponse.self)
    }

    // MARK: - internals

    private func send<T: Decodable>(method: String, path: String, body: [String: Any]?, as: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("usr-imessage", forHTTPHeaderField: "x-user-id")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "WL", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let err = envelope.error { throw NSError(domain: "WL", code: -3, userInfo: [NSLocalizedDescriptionKey: err]) }
        guard let payload = envelope.data else { throw NSError(domain: "WL", code: -4, userInfo: [NSLocalizedDescriptionKey: "Empty envelope"]) }
        return payload
    }
}
