import Foundation

/// Thin URLSession-based client for the Fastify API at `PMWConfig.apiBaseURL`.
/// Mirrors the web's `apps/web/src/api.ts`. All requests carry the dev
/// `x-user-id` header until Supabase Auth is wired.
///
/// The client is intentionally tiny: no caching, no retry. It's meant to be
/// called from PMWStore which owns the data state.
struct PMWAPIClient {
    static let shared = PMWAPIClient()

    // MARK: - Wire types (mirror the API's JSON envelope) -----------------

    struct Envelope<T: Decodable>: Decodable { let data: T?; let error: String? }

    struct RoomPayload: Decodable {
        let room: APIRoom
        let songs: [APISong]
        let versions: [APIVersion]
        let assets: [APIAsset]
        let notes: [APINote]
        let links: [APILink]
    }

    struct SongPayload: Decodable {
        let song: APISong
        let versions: [APIVersion]
        let assets: [APIAsset]
        let currentVersion: APIVersion?
        let notes: [APINote]
        let approvals: [APIApproval]
        let links: [APILink]
    }

    struct SharedPayload: Decodable {
        let link: APILink
        let songs: [APISong]
        let versions: [APIVersion]
        let assets: [APIAsset]
        let rooms: [APIRoom]
    }

    struct APIRoom: Decodable {
        let room_id: String
        let title: String
        let description: String?
    }

    struct APISong: Decodable {
        let song_id: String
        let primary_room_id: String?
        let title: String
        let artist_display_name: String?
        let project_name: String?
        let status: String
        let current_version_id: String?
        let approved_version_id: String?
        let bpm: Int?
        let song_key: String?
        let explicit_flag: Bool?
    }

    struct APIVersion: Decodable {
        let version_id: String
        let song_id: String
        let version_number: Int
        let version_label: String?
        let type: String
        let parent_version_id: String?
        let is_current: Bool
        let is_approved: Bool
        let file_asset_id: String
        let created_at: String?
    }

    struct APIAsset: Decodable {
        let asset_id: String
        let original_filename: String
        let duration_ms: Int?
        let loudness_lufs: Double?
        let waveform_peaks: [Double]?
        let playback_url: String?
        let key_stems_zip: String?
    }

    struct APINote: Decodable {
        let note_id: String
        let song_id: String
        let anchor_version_id: String
        let author_user_id: String?
        let author_guest_label: String?
        let body: String?
        let timestamp_start_ms: Int?
        let timestamp_end_ms: Int?
        let scope: String
        let status: String
    }

    struct APIApproval: Decodable {
        let approval_id: String
        let version_id: String
        let state: String
        let note: String?
    }

    struct APILink: Decodable {
        let link_id: String
        let target_type: String
        let target_id: String
        let link_name: String?
        let access_mode: String?
        let version_policy: String
        let watermark_enabled: Bool
    }

    // MARK: - Calls -------------------------------------------------------

    func room(_ id: String = "room-secret-album") async throws -> RoomPayload {
        try await get("/rooms/\(id)", as: RoomPayload.self)
    }

    func song(_ id: String) async throws -> SongPayload {
        try await get("/songs/\(id)", as: SongPayload.self)
    }

    func shared(token: String) async throws -> SharedPayload {
        try await get("/shared/\(token)", as: SharedPayload.self)
    }

    @discardableResult
    func createNote(songID: String, versionID: String, body: String,
                    timestampMS: Int?, author: String?) async throws -> APINote {
        var payload: [String: Any] = [
            "song_id": songID,
            "anchor_version_id": versionID,
            "body": body,
            "scope": "song",
            "visibility": "everyone"
        ]
        if let timestampMS { payload["timestamp_start_ms"] = timestampMS }
        if let author { payload["author_guest_label"] = author }
        return try await post("/notes", body: payload, as: APINote.self)
    }

    @discardableResult
    func approve(versionID: String, state: String = "approved") async throws -> APIApproval {
        try await post("/versions/\(versionID)/approvals",
                       body: ["state": state], as: APIApproval.self)
    }

    // MARK: - Internals ---------------------------------------------------

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try await send(method: "GET", path: path, body: nil, as: T.self)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], as: T.Type) async throws -> T {
        try await send(method: "POST", path: path, body: body, as: T.self)
    }

    private func send<T: Decodable>(method: String, path: String, body: [String: Any]?, as: T.Type) async throws -> T {
        var components = URLComponents(url: PMWConfig.apiBaseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        var request = URLRequest(url: components?.url ?? PMWConfig.apiBaseURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(PMWConfig.devUserId,  forHTTPHeaderField: "x-user-id")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "PMWAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Request failed: \(response)"])
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let err = envelope.error {
            throw NSError(domain: "PMWAPI", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: err])
        }
        guard let payload = envelope.data else {
            throw NSError(domain: "PMWAPI", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Empty envelope"])
        }
        return payload
    }
}
