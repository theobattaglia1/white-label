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

    struct ProjectPayload: Decodable {
        let project: APIProject
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
        let projects: [APIProject]
    }

    struct APIProject: Decodable {
        let project_id: String
        let title: String
        let description: String?
    }

    struct APISong: Decodable {
        let song_id: String
        let primary_project_id: String?
        let title: String
        let artist_display_name: String?
        let project_name: String?
        let status: String
        let current_version_id: String?
        let approved_version_id: String?
        let bpm: Int?
        let song_key: String?
        let explicit_flag: Bool?
        let release_readiness_status: String?
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
        let allow_approval: Bool?
        let allow_comments: Bool?
        let download_policy: String?
    }

    // MARK: - Calls -------------------------------------------------------

    func project(_ id: String = "room-hudson-ingram-lp") async throws -> ProjectPayload {
        try await get("/projects/\(id)", as: ProjectPayload.self)
    }

    // MARK: - Library / Projects / Playlists -----------------------------

    struct APIProjectSummary: Decodable {
        let project_id: String
        let title: String
        let type: String
        let song_count: Int
        let open_note_count: Int
    }

    struct APILibraryItem: Decodable {
        struct ProjectRef: Decodable { let project_id: String; let title: String; let type: String }
        let song: APISong
        let project: ProjectRef?
        let current_version: APIVersion?
        let asset: APIAsset?
    }

    struct APIPlaylist: Decodable {
        let playlist_id: String
        let workspace_id: String
        let title: String
        let description: String?
        let cover_seed: String
        let is_pinned: Bool?
        let item_count: Int?
        let preview_titles: [String]?
    }

    struct APIPlaylistItem: Decodable {
        let playlist_item_id: String
        let playlist_id: String
        let song_id: String
        let position: Int
        let note: String?
    }

    struct APIPlaylistDetail: Decodable {
        struct Entry: Decodable {
            let item: APIPlaylistItem
            let song: APISong?
            let current_version: APIVersion?
            let asset: APIAsset?
        }
        let playlist: APIPlaylist
        let items: [Entry]
    }

    func projectsSummary(workspaceID: String = "wsp-amf-private") async throws -> [APIProjectSummary] {
        try await get("/workspaces/\(workspaceID)/projects-summary", as: [APIProjectSummary].self)
    }

    func library(workspaceID: String = "wsp-amf-private") async throws -> [APILibraryItem] {
        try await get("/workspaces/\(workspaceID)/library", as: [APILibraryItem].self)
    }

    func playlists(workspaceID: String = "wsp-amf-private") async throws -> [APIPlaylist] {
        try await get("/workspaces/\(workspaceID)/playlists", as: [APIPlaylist].self)
    }

    func playlist(_ id: String) async throws -> APIPlaylistDetail {
        try await get("/playlists/\(id)", as: APIPlaylistDetail.self)
    }

    @discardableResult
    func addToPlaylist(playlistID: String, songID: String) async throws -> APIPlaylistItem {
        try await post("/playlists/\(playlistID)/items", body: ["song_id": songID], as: APIPlaylistItem.self)
    }

    @discardableResult
    func createPlaylist(workspaceID: String = "wsp-amf-private", title: String) async throws -> APIPlaylist {
        try await post("/playlists", body: ["workspace_id": workspaceID, "title": title], as: APIPlaylist.self)
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

    /// Recipient-side approval — POST /shared/:token/approve.
    @discardableResult
    func approve(token: String, versionID: String,
                 state: String = "approved", note: String? = nil) async throws -> APIApproval {
        var body: [String: Any] = ["version_id": versionID, "state": state]
        if let note { body["note"] = note }
        return try await post("/shared/\(token)/approve", body: body, as: APIApproval.self)
    }

    // MARK: - Internals ---------------------------------------------------

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try await send(method: "GET", path: path, body: nil, as: T.self)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], as: T.Type) async throws -> T {
        try await send(method: "POST", path: path, body: body, as: T.self)
    }

    private func send<T: Decodable>(method: String, path: String, body: [String: Any]?, as: T.Type) async throws -> T {
        let components = URLComponents(url: PMWConfig.apiBaseURL.appendingPathComponent(path),
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
