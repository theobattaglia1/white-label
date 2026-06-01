import Foundation

// MARK: - API errors ----------------------------------------------------------

enum PMWAPIError: Error, LocalizedError {
    /// Real auth is on and no valid token could be obtained (auth rejection,
    /// not a network failure). Callers should re-present the sign-in gate.
    case unauthenticated

    var errorDescription: String? {
        switch self {
        case .unauthenticated: return "You must be signed in to perform this action."
        }
    }
}

// MARK: - Client --------------------------------------------------------------

/// Thin URLSession-based client for the Fastify API at `PMWConfig.apiBaseURL`.
/// Mirrors the web's `apps/web/src/api.ts`.
///
/// Header injection:
///   - `x-user-id: <devUserId>` — sent ONLY when `PMWConfig.useRealAuth` is
///     false (dev/sample mode). When real auth is on, the Bearer JWT is the
///     identity; the legacy header is omitted to avoid mis-attribution.
///   - `Authorization: Bearer <token>` — added when `PMWConfig.useRealAuth`
///     is true AND a valid session token is available from `PMWSession.shared`.
///     Token is fetched (and auto-refreshed if near expiry) via
///     `PMWSession.validAccessToken()`, which is async — the existing `send()`
///     is already `async throws` so this adds zero protocol surface.
///
/// The client is intentionally tiny: no caching, no retry. It's meant to be
/// called from PMWStore which owns the data state.
struct PMWAPIClient {
    static let shared = PMWAPIClient()

    /// Dedicated session with a 20 s request timeout (matches PMWAuthClient)
    /// so API calls fail fast on a dead network instead of hanging 60 s.
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

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

    func room(_ id: String = "room-hudson-ingram-lp") async throws -> RoomPayload {
        try await get("/rooms/\(id)", as: RoomPayload.self)
    }

    // MARK: - Library / Rooms / Playlists --------------------------------

    struct APIRoomSummary: Decodable {
        let room_id: String
        let title: String
        let type: String
        let song_count: Int
        let open_note_count: Int
    }

    struct APILibraryItem: Decodable {
        struct RoomRef: Decodable { let room_id: String; let title: String; let type: String }
        let song: APISong
        let room: RoomRef?
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

    func roomsSummary(workspaceID: String = "wsp-amf-private") async throws -> [APIRoomSummary] {
        try await get("/workspaces/\(workspaceID)/rooms-summary", as: [APIRoomSummary].self)
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

    // MARK: - Links -------------------------------------------------------

    struct APICreatedLink: Decodable {
        let link: APILink
        let token: String
    }

    /// Create a share link for a song, room, or playlist.
    /// Mirrors `api.createLink` in apps/web/src/api.ts.
    @discardableResult
    func createLink(workspaceID: String = "wsp-amf-private",
                    targetType: String,
                    targetID: String,
                    linkName: String? = nil) async throws -> APICreatedLink {
        var body: [String: Any] = [
            "workspace_id": workspaceID,
            "target_type": targetType,
            "target_id": targetID,
            "access_mode": "identity_required",
            "version_policy": "latest_only",
            "download_policy": "none",
            "watermark_enabled": true,
            "allow_comments": true,
            "allow_approval": true,
            "allow_forwarding": false
        ]
        if let linkName { body["link_name"] = linkName }
        return try await post("/links", body: body, as: APICreatedLink.self)
    }

    // MARK: - Saved views --------------------------------------------------

    struct APISavedView: Decodable {
        let view_id: String
        let name: String
        let filter: [String: String]
    }

    func savedViews(workspaceID: String = "wsp-amf-private") async throws -> [APISavedView] {
        try await get("/workspaces/\(workspaceID)/saved-views", as: [APISavedView].self)
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
        if PMWConfig.useRealAuth {
            // Real auth: Bearer JWT is the identity. Omit x-user-id so writes
            // are not mis-attributed to the dev user.
            // `validAccessToken()` is async and handles auto-refresh transparently,
            // including the single-flight dedup and offline-stale fallback.
            guard let token = await PMWSession.shared.validAccessToken() else {
                // Genuine auth failure (not offline) — surface it so callers
                // can re-present the sign-in gate.
                throw PMWAPIError.unauthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            // Dev/sample mode (default): legacy identity header, no JWT.
            // This path is completely unchanged from the original behaviour.
            request.setValue(PMWConfig.devUserId, forHTTPHeaderField: "x-user-id")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        // Use the dedicated session (20 s request timeout) instead of
        // URLSession.shared (60 s default, 7-day resource timeout).
        let (data, response) = try await urlSession.data(for: request)
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
