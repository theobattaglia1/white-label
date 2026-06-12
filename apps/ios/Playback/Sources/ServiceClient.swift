import Foundation
import AVFoundation

enum ServiceError: Error, LocalizedError {
    case emptyResponse
    case requestFailed(String)
    case httpStatus(Int, String)
    case uploadFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "The service returned an empty response."
        case .requestFailed(let message): return message
        case .httpStatus(_, let message): return message
        case .uploadFailed(let status, let detail): return "Upload failed (\(status)): \(detail)"
        }
    }
}

extension Error {
    /// HTTP status carried by a ServiceError, if any — lets share UI tell
    /// 422 ("song hasn't finished syncing") from 503 (storage busy) apart.
    var serviceHTTPStatus: Int? {
        switch self as? ServiceError {
        case .httpStatus(let status, _), .uploadFailed(let status, _): return status
        default: return nil
        }
    }

    /// True when the API rejected our identity even after the one automatic
    /// session refresh + retry (.httpStatus 401 — deliberately NOT a 401 from
    /// a signed-URL PUT, which is a storage problem, not an identity one).
    /// The upload queue parks on this instead of burning backoff retries.
    var isAuthFailure: Bool {
        if case .httpStatus(401, _)? = self as? ServiceError { return true }
        return false
    }
}

struct ServiceClient {
    static let shared = ServiceClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let error: String?
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
        let artwork_url: String?
    }

    struct APIVersion: Decodable {
        let version_id: String
        let song_id: String
        let version_number: Int
        let version_label: String?
        let type: String
        let is_current: Bool
        let is_approved: Bool
        let file_asset_id: String
    }

    struct APIAsset: Decodable {
        let asset_id: String
        let original_filename: String
        let duration_ms: Int?
        let loudness_lufs: Double?
        let playback_url: String?
        let key_stems_zip: String?
    }

    struct APILibraryItem: Decodable {
        struct RoomRef: Decodable {
            let room_id: String
            let title: String
            let type: String
        }
        let song: APISong
        let room: RoomRef?
        let current_version: APIVersion?
        let asset: APIAsset?
    }

    struct APIRoomSummary: Decodable {
        let room_id: String
        let title: String
        let type: String
        let song_count: Int
        let open_note_count: Int
    }

    struct APISimpleRoom: Decodable {
        let room_id: String
        let title: String
        let type: String
    }

    struct APIPlaylist: Decodable {
        let playlist_id: String
        let workspace_id: String
        let title: String
        let description: String?
        let cover_seed: String?
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

    struct APISavedView: Decodable {
        let view_id: String
        let name: String
        let filter: [String: String]?
    }

    struct APICreatedLink: Decodable {
        struct Link: Decodable {
            let link_id: String
            let target_type: String
            let target_id: String
        }
        let link: Link
        let token: String
    }

    struct APIShareSession: Decodable, Identifiable, Hashable {
        var id: String { share_session_id }
        let share_session_id: String
        let song_id: String
        let room_id: String?
        let version_id: String?
        let share_type: String
        let decision_request_type: String
        let context_note: String?
        let expires_at: String?
        let replay_grants_count: Int
        let status: String
        let created_at: String
        let updated_at: String
    }

    struct APIShareSessionRecipient: Decodable, Identifiable, Hashable {
        var id: String { recipient_id }
        let recipient_id: String
        let share_session_id: String
        let recipient_email: String?
        let recipient_phone: String?
        let display_name: String?
        let access_state: String
        let opened_at: String?
        let started_at: String?
        let completed_at: String?
        let replay_requested_at: String?
        let replay_granted_at: String?
        let last_position_ms: Int?
    }

    struct APIDecisionResponse: Decodable, Identifiable, Hashable {
        var id: String { decision_response_id }
        let decision_response_id: String
        let response_value: String
        let text_note: String?
        let transcript: String?
        let created_at: String
    }

    struct APITimestampedReaction: Decodable, Identifiable, Hashable {
        var id: String { timestamped_reaction_id }
        let timestamped_reaction_id: String
        let playback_position_ms: Int
        let reaction_type: String
        let intensity: Int?
        let note_text: String?
        let created_at: String
    }

    struct APIListeningReport: Decodable, Identifiable, Hashable {
        var id: String { listening_report_id }
        let listening_report_id: String
        let report_type: String
        let visibility: String
        let summary_json: APIJSONValue
        let created_at: String
        let updated_at: String
    }

    enum APIJSONValue: Decodable, Hashable, CustomStringConvertible {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: APIJSONValue])
        case array([APIJSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([String: APIJSONValue].self) { self = .object(value) }
            else if let value = try? container.decode([APIJSONValue].self) { self = .array(value) }
            else { self = .null }
        }

        var description: String {
            switch self {
            case .string(let value): return value
            case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
            case .bool(let value): return value ? "true" : "false"
            case .object(let value):
                return value.map { "\($0.key): \($0.value.description)" }.sorted().joined(separator: "\n")
            case .array(let value): return value.map(\.description).joined(separator: ", ")
            case .null: return ""
            }
        }
    }

    struct APICreatedFirstListen: Decodable {
        let session: APIShareSession
        let recipient: APIShareSessionRecipient
        let token: String
        let url_path: String
    }

    struct APIFirstListenDetail: Decodable {
        let session: APIShareSession
        let recipients: [APIShareSessionRecipient]
        let decisions: [APIDecisionResponse]
        let reactions: [APITimestampedReaction]
        let song: APISong
        let version: APIVersion
        let room: APISimpleRoom?
    }

    struct APIListeningRoom: Decodable, Identifiable, Hashable {
        var id: String { listening_room_id }
        let listening_room_id: String
        let room_id: String?
        let room_type: String
        let title: String
        let context_note: String?
        let decision_request_type: String?
        let scheduled_start_at: String?
        let started_at: String?
        let ended_at: String?
        let lifecycle_state: String
        let retention_policy: String
    }

    struct APIListeningRoomTrack: Decodable, Identifiable, Hashable {
        var id: String { listening_room_track_id }
        let listening_room_track_id: String
        let song_id: String
        let version_id: String?
        let sort_order: Int
    }

    struct APIListeningRoomParticipant: Decodable, Identifiable, Hashable {
        var id: String { participant_id }
        let participant_id: String
        let display_name: String?
        let recipient_email: String?
        let role_in_room: String
        let joined_at: String?
        let completed_at: String?
        let first_take_submitted_at: String?
    }

    struct APIListeningRoomState: Decodable, Hashable {
        let playback_state: String
        let host_position_ms: Int
        let host_started_at_server_time: String?
        let updated_at: String
    }

    struct APICreatedListeningRoom: Decodable {
        let room: APIListeningRoom
        let tracks: [APIListeningRoomTrack]
        let host: APIListeningRoomParticipant
        let token: String
        let url_path: String
    }

    struct APIListeningRoomDetail: Decodable {
        let room: APIListeningRoom
        let tracks: [APIListeningRoomTrack]
        let participants: [APIListeningRoomParticipant]
        let state: APIListeningRoomState
        let reactions: [APITimestampedReaction]
        let decisions: [APIDecisionResponse]
        let report: APIListeningReport?
    }

    struct APISignUpload: Decodable {
        let uploadUrl: String
        let storagePath: String
        let publicUrl: String
        let expiresInSeconds: Int
    }

    struct APIFinalizeNewSong: Decodable {
        let songExternalId: String
        let versionExternalId: String
        let assetExternalId: String
        let versionNumber: Int
        let roomExternalId: String?
    }

    struct APIRemoveResult: Decodable {
        let removed: Int?
    }

    struct APIDeleteSongResult: Decodable {
        let deleted: Bool
    }

    struct APIReorderResult: Decodable {
        let reordered: Int
    }

    struct APIUser: Decodable {
        let user_id: String
        let email: String
        let display_name: String
        let member_number: Int?
    }

    struct APIWorkspace: Decodable {
        let workspace_id: String
        let name: String
        let owner_user_id: String
    }

    struct APIMembership: Decodable {
        let membership_id: String
        let workspace_id: String
        let user_id: String
        let role: String
    }

    struct MePayload: Decodable {
        let user: APIUser
        let memberships: [APIMembership]
        let workspaces: [APIWorkspace]

        enum CodingKeys: String, CodingKey {
            case user
            case memberships
            case workspaces
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            user = try container.decode(APIUser.self, forKey: .user)
            memberships = try container.decode([APIMembership].self, forKey: .memberships)
            workspaces = (try? container.decode([APIWorkspace].self, forKey: .workspaces)) ?? []
        }
    }

    struct APIShareRecipient: Decodable, Identifiable, Hashable {
        var id: String { recipient_id }
        let recipient_id: String
        let link_id: String
        let email: String
        let display_name: String?
        let role: String
        let invited_by: String
        let invited_at: String
        let last_sent_at: String?
        let revoked_at: String?
    }

    struct APIInviteRecipientsResult: Decodable {
        let recipients: [APIShareRecipient]
        let delivery: String
    }

    struct APIMember: Decodable, Identifiable {
        var id: String { user_id }
        let user_id: String
        let display_name: String
        let role: String
        let member_number: Int?
    }

    struct APIInvite: Decodable, Identifiable {
        var id: String { invite_id }
        let invite_id: String
        let email: String
        let role: String
        let display_name: String?
        let invited_at: String
    }

    struct APIInviteResult: Decodable {
        let invited: Bool
        let email: String
        let role: String
        let invite_id: String
    }

    struct APIRevokeInviteResult: Decodable {
        let revoked: Bool
    }

    struct APINote: Decodable {
        let note_id: String
        let song_id: String
        let anchor_version_id: String
        let body: String
        let status: String
        let timestamp_start_ms: Int?
        let author_user_id: String?
        let author_guest_label: String?
        let author_display_name: String?
        let anchor_version_label: String?
    }

    struct APIInboxItem: Decodable {
        struct MinSong: Decodable {
            let song_id: String
            let title: String
            let artist_display_name: String?
        }
        struct MinRoom: Decodable {
            let room_id: String
            let title: String
        }
        let song: MinSong
        let room: MinRoom?
        let shared_by: String
        let new_since_last_listen: Bool
    }

    struct APIUserPatch: Decodable {
        let user_id: String
        let display_name: String
    }

    struct APIAccessRequest: Decodable, Identifiable, Hashable {
        var id: String { request_id }
        let request_id: String
        let workspace_id: String
        let name: String
        let email: String
        let source_token: String?
        let source_song_title: String?
        let status: String
        let created_at: String
    }

    struct APIAccessInvite: Decodable, Hashable {
        let token: String
        let url: String
        let workspace_name: String?
        let email: String
        let role: String
    }

    struct APIResolvedAccessRequest: Decodable {
        let request: APIAccessRequest
        let invite: APIAccessInvite?
    }

    func me() async throws -> MePayload {
        try await get("/me", as: MePayload.self)
    }

    func library(workspaceID: String? = nil) async throws -> [APILibraryItem] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/library", as: [APILibraryItem].self)
    }

    func roomsSummary(workspaceID: String? = nil) async throws -> [APIRoomSummary] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/rooms-summary", as: [APIRoomSummary].self)
    }

    func playlists(workspaceID: String? = nil) async throws -> [APIPlaylist] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/playlists", as: [APIPlaylist].self)
    }

    func playlist(_ id: String) async throws -> APIPlaylistDetail {
        try await get("/playlists/\(id)", as: APIPlaylistDetail.self)
    }

    func savedViews(workspaceID: String? = nil) async throws -> [APISavedView] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/saved-views", as: [APISavedView].self)
    }

    @discardableResult
    func createPlaylist(title: String, workspaceID: String? = nil) async throws -> APIPlaylist {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await post("/playlists", body: ["workspace_id": id, "title": title], as: APIPlaylist.self)
    }

    @discardableResult
    func addToPlaylist(playlistID: String, songID: String) async throws -> APIPlaylistItem {
        try await post("/playlists/\(playlistID)/items", body: ["song_id": songID], as: APIPlaylistItem.self)
    }

    func removeFromPlaylist(playlistID: String, itemID: String) async throws {
        _ = try await delete("/playlists/\(playlistID)/items/\(itemID)", as: APIRemoveResult.self)
    }

    func deleteSong(_ id: String) async throws {
        _ = try await delete("/songs/\(id)", as: APIDeleteSongResult.self)
    }

    func reorderPlaylist(playlistID: String, itemIDs: [String]) async throws {
        _ = try await post("/playlists/\(playlistID)/reorder", body: ["item_ids": itemIDs], as: APIReorderResult.self)
    }

    @discardableResult
    func patchSong(
        _ id: String,
        title: String,
        artist: String,
        project: String,
        artworkPath: String? = nil,
        artworkChanged: Bool = false
    ) async throws -> APILibraryItem? {
        var payload: [String: Any] = [
            "title": title,
            "artist_display_name": artist,
            "project_name": project,
        ]

        if artworkChanged {
            if let artworkPath,
               let artworkURL = localFileURL(for: artworkPath) {
                let workspaceID = await resolvedWorkspaceID(nil)
                let artworkContentType = contentType(for: artworkURL)
                let artworkSigned = try await post(
                    "/storage/sign-upload",
                    body: [
                        "filename": artworkURL.lastPathComponent,
                        "contentType": artworkContentType,
                        "workspaceExternalId": workspaceID,
                        "songExternalId": id
                    ],
                    as: APISignUpload.self
                )
                try await uploadFile(artworkURL, to: artworkSigned.uploadUrl, contentType: artworkContentType)
                payload["artwork_key"] = artworkSigned.storagePath
                payload["artwork_url"] = artworkSigned.publicUrl
            } else {
                payload["artwork_key"] = NSNull()
                payload["artwork_url"] = NSNull()
            }
        }

        _ = try await patch("/songs/\(id)", body: payload, as: SongPayload.self)
        return nil
    }

    struct SongPayload: Decodable {
        let song: APISong
    }

    func patchVersion(_ id: String, versionLabel: String) async throws {
        _ = try await patch("/versions/\(id)", body: ["version_label": versionLabel], as: APIVersion.self)
    }

    func createShareLink(targetType: String, targetID: String, allowDownload: Bool = false) async throws -> APICreatedLink {
        let workspaceID = await resolvedWorkspaceID(nil)
        let body: [String: Any] = [
            "workspace_id": workspaceID,
            "target_type": targetType,
            "target_id": targetID,
            "access_mode": "public",
            "version_policy": "latest_only",
            "download_policy": allowDownload ? "current" : "none",
            "watermark_enabled": true,
            "allow_comments": true,
            "allow_approval": true,
            "allow_forwarding": false,
        ]
        return try await post("/links", body: body, as: APICreatedLink.self)
    }

    func createFirstListen(
        trackID: String,
        versionID: String?,
        decisionRequestType: String,
        contextNote: String?,
        recipientEmail: String?,
        displayName: String?,
        expiresAt: Date?
    ) async throws -> APICreatedFirstListen {
        var body: [String: Any] = [
            "song_id": trackID,
            "decision_request_type": decisionRequestType,
        ]
        if let versionID { body["version_id"] = versionID }
        if let contextNote, !contextNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["context_note"] = contextNote
        }
        if let recipientEmail, !recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["recipient_email"] = recipientEmail
        }
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["display_name"] = displayName
        }
        if let expiresAt { body["expires_at"] = Self.isoFormatter.string(from: expiresAt) }
        return try await post("/first-listens", body: body, as: APICreatedFirstListen.self)
    }

    func firstListen(_ id: String) async throws -> APIFirstListenDetail {
        try await get("/first-listens/\(id)", as: APIFirstListenDetail.self)
    }

    func firstListenReport(_ id: String) async throws -> APIListeningReport {
        try await get("/first-listens/\(id)/report", as: APIListeningReport.self)
    }

    func grantFirstListenReplay(sessionID: String, recipientID: String) async throws -> APIFirstListenDetail {
        try await post("/first-listens/\(sessionID)/recipients/\(recipientID)/grant-replay", body: [:], as: APIFirstListenDetail.self)
    }

    func createListeningRoom(
        trackID: String,
        versionID: String?,
        roomType: String,
        title: String?,
        contextNote: String?,
        decisionRequestType: String,
        scheduledStartAt: Date?,
        retentionPolicy: String
    ) async throws -> APICreatedListeningRoom {
        var body: [String: Any] = [
            "song_id": trackID,
            "room_type": roomType,
            "decision_request_type": decisionRequestType,
            "retention_policy": retentionPolicy,
        ]
        if let versionID { body["version_id"] = versionID }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["title"] = title }
        if let contextNote, !contextNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["context_note"] = contextNote }
        if let scheduledStartAt { body["scheduled_start_at"] = Self.isoFormatter.string(from: scheduledStartAt) }
        return try await post("/listening-rooms", body: body, as: APICreatedListeningRoom.self)
    }

    func listeningRoom(_ id: String) async throws -> APIListeningRoomDetail {
        try await get("/listening-rooms/\(id)", as: APIListeningRoomDetail.self)
    }

    func startListeningRoom(_ id: String) async throws -> APIListeningRoomDetail {
        try await post("/listening-rooms/\(id)/start", body: ["host_position_ms": 0], as: APIListeningRoomDetail.self)
    }

    func pauseListeningRoom(_ id: String, positionMs: Int) async throws -> APIListeningRoomDetail {
        try await post("/listening-rooms/\(id)/state", body: ["playback_state": "paused", "host_position_ms": positionMs], as: APIListeningRoomDetail.self)
    }

    func endListeningRoom(_ id: String) async throws -> APIListeningReport {
        try await post("/listening-rooms/\(id)/end", body: [:], as: APIListeningReport.self)
    }

    func members(workspaceID: String? = nil) async throws -> [APIMember] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/members", as: [APIMember].self)
    }

    func listInvites(workspaceID: String? = nil) async throws -> [APIInvite] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/invites", as: [APIInvite].self)
    }

    func sendInvite(email: String, role: String, displayName: String? = nil, workspaceID: String? = nil) async throws -> APIInviteResult {
        let id = await resolvedWorkspaceID(workspaceID)
        var body: [String: Any] = ["email": email, "role": role]
        if let displayName { body["display_name"] = displayName }
        return try await post("/workspaces/\(id)/invite", body: body, as: APIInviteResult.self)
    }

    func revokeInvite(inviteID: String, workspaceID: String? = nil) async throws {
        let id = await resolvedWorkspaceID(workspaceID)
        _ = try await delete("/workspaces/\(id)/invites/\(inviteID)", as: APIRevokeInviteResult.self)
    }

    func inviteRecipients(linkID: String, recipients: [(email: String, displayName: String?, role: String)]) async throws -> APIInviteRecipientsResult {
        let payload = recipients.map { recipient in
            [
                "email": recipient.email,
                "display_name": recipient.displayName ?? "",
                "role": recipient.role,
            ]
        }
        return try await post("/links/\(linkID)/recipients", body: ["recipients": payload], as: APIInviteRecipientsResult.self)
    }

    func listRecipients(linkID: String) async throws -> [APIShareRecipient] {
        try await get("/links/\(linkID)/recipients", as: [APIShareRecipient].self)
    }

    func patchRecipient(linkID: String, recipientID: String, role: String) async throws -> APIShareRecipient {
        try await patch("/links/\(linkID)/recipients/\(recipientID)", body: ["role": role], as: APIShareRecipient.self)
    }

    func revokeRecipient(linkID: String, recipientID: String) async throws -> APIShareRecipient {
        try await delete("/links/\(linkID)/recipients/\(recipientID)", as: APIShareRecipient.self)
    }

    struct APIJoinLink: Decodable {
        let token: String
        let url: String
        let workspace_name: String?
    }

    func generateJoinLink(workspaceID: String? = nil, role: String = "viewer") async throws -> APIJoinLink {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await post("/workspaces/\(id)/join-links", body: ["role": role], as: APIJoinLink.self)
    }

    func notes(songID: String) async throws -> [APINote] {
        try await get("/songs/\(songID)/notes", as: [APINote].self)
    }

    @discardableResult
    func createNote(songID: String, versionID: String, body: String, positionMs: Int?) async throws -> APINote {
        var payload: [String: Any] = [
            "song_id": songID,
            "anchor_version_id": versionID,
            "body": body,
        ]
        if let ms = positionMs { payload["timestamp_start_ms"] = ms }
        return try await post("/notes", body: payload, as: APINote.self)
    }

    @discardableResult
    func patchNote(noteID: String, status: String?, body: String?) async throws -> APINote {
        var payload: [String: Any] = [:]
        if let status { payload["status"] = status }
        if let body { payload["body"] = body }
        return try await patch("/notes/\(noteID)", body: payload, as: APINote.self)
    }

    func inbox() async throws -> [APIInboxItem] {
        try await get("/inbox", as: [APIInboxItem].self)
    }

    func accessRequests(workspaceID: String? = nil) async throws -> [APIAccessRequest] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/access-requests", as: [APIAccessRequest].self)
    }

    func resolveAccessRequest(requestID: String, action: String) async throws -> APIResolvedAccessRequest {
        try await post("/access-requests/\(requestID)/resolve", body: ["action": action], as: APIResolvedAccessRequest.self)
    }

    func getPins(workspaceID: String? = nil) async throws -> [String] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await get("/workspaces/\(id)/pins", as: [String].self)
    }

    @discardableResult
    func putPins(_ pins: [String], workspaceID: String? = nil) async throws -> [String] {
        let id = await resolvedWorkspaceID(workspaceID)
        return try await put("/workspaces/\(id)/pins", body: ["pins": pins], as: [String].self)
    }

    @discardableResult
    func patchMe(displayName: String) async throws -> APIUserPatch {
        try await patch("/me", body: ["display_name": displayName], as: APIUserPatch.self)
    }

    func uploadNewSong(
        audioURL: URL,
        title: String,
        artist: String,
        project: String,
        versionLabel: String,
        durationMs: Int,
        artworkPath: String?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> APIFinalizeNewSong {
        let workspaceID = await resolvedWorkspaceID(nil)
        let filename = audioURL.lastPathComponent
        let audioContentType = contentType(for: audioURL)
        let signed = try await post(
            "/storage/sign-upload",
            body: ["filename": filename, "contentType": audioContentType, "workspaceExternalId": workspaceID],
            as: APISignUpload.self
        )

        try await uploadFile(audioURL, to: signed.uploadUrl, contentType: audioContentType, progress: progress)

        var artworkStoragePath: String?
        var artworkPublicUrl: String?
        if let artworkPath,
           let artworkURL = localFileURL(for: artworkPath) {
            let artworkContentType = contentType(for: artworkURL)
            let artworkSigned = try await post(
                "/storage/sign-upload",
                body: ["filename": artworkURL.lastPathComponent, "contentType": artworkContentType, "workspaceExternalId": workspaceID],
                as: APISignUpload.self
            )
            try await uploadFile(artworkURL, to: artworkSigned.uploadUrl, contentType: artworkContentType)
            artworkStoragePath = artworkSigned.storagePath
            artworkPublicUrl = artworkSigned.publicUrl
        }

        var finalize: [String: Any] = [
            "storagePath": signed.storagePath,
            "publicUrl": signed.publicUrl,
            "filename": filename,
            "contentType": audioContentType,
            "fileSizeBytes": fileSize(audioURL),
            "durationMs": durationMs,
            "workspaceExternalId": workspaceID,
            "title": title,
            "artist": artist,
            "projectName": project,
            "versionLabel": versionLabel,
            "versionType": "demo",
        ]
        if let artworkStoragePath {
            finalize["artworkStoragePath"] = artworkStoragePath
        }
        if let artworkPublicUrl {
            finalize["artworkPublicUrl"] = artworkPublicUrl
        }

        return try await post("/storage/finalize-new-song", body: finalize, as: APIFinalizeNewSong.self)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(method: "GET", path: path, body: nil, as: type)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        try await send(method: "POST", path: path, body: body, as: type)
    }

    private func patch<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        try await send(method: "PATCH", path: path, body: body, as: type)
    }

    private func put<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        try await send(method: "PUT", path: path, body: body, as: type)
    }

    private func delete<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(method: "DELETE", path: path, body: nil, as: type)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func resolvedWorkspaceID(_ workspaceID: String?) async -> String {
        if let workspaceID { return workspaceID }
        if Config.useRealAuth {
            return await PlaybackAuthSession.shared.activeWorkspaceID
        }
        return Config.defaultWorkspaceID
    }

    private func send<T: Decodable>(method: String, path: String, body: [String: Any]?, as type: T.Type) async throws -> T {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var sentToken: String?
        if Config.useRealAuth {
            // Proactive: refreshes the Supabase session when it is near expiry.
            guard let token = await PlaybackAuthSession.shared.validAccessToken() else {
                throw ServiceError.httpStatus(401, "Session expired — sign in again to continue.")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            sentToken = token
        } else {
            request.setValue(Config.devUserID, forHTTPHeaderField: "x-user-id")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        var (data, http) = try await perform(request)

        // Reactive: the server can 401 a token the client still believes is
        // fresh (session revoked elsewhere, signing-key rotation, clock skew).
        // Refresh the session once and retry the request once — every caller
        // (library refresh, upload queue, profile) gets this for free. Only
        // when the refresh itself is rejected does auth failure surface.
        if http.statusCode == 401, let rejected = sentToken {
            guard let fresh = await PlaybackAuthSession.shared.accessTokenAfterRejection(of: rejected) else {
                throw ServiceError.httpStatus(401, "Session expired — sign in again to continue.")
            }
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "authorization")
            (data, http) = try await perform(request)
        }

        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data)["error"])
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ServiceError.httpStatus(http.statusCode, message)
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let error = envelope.error { throw ServiceError.requestFailed(error) }
        guard let value = envelope.data else { throw ServiceError.emptyResponse }
        return value
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.requestFailed("No HTTP response.")
        }
        return (data, http)
    }

    /// Foreground URLSession PUT. Progress (for the upload queue's pending
    /// rows) arrives via a per-task delegate — no timers. A background
    /// URLSessionConfiguration (uploads surviving app suspension) needs a
    /// delegate-based rewrite of this async path; the queue compensates
    /// with persistence + aggressive auto-resume. Follow-up.
    private func uploadFile(
        _ url: URL,
        to signedURL: String,
        contentType: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let destination = URL(string: signedURL) else {
            throw ServiceError.requestFailed("Upload URL was invalid.")
        }
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let delegate = progress.map { UploadProgressObserver(onProgress: $0) }
        let (_, response) = try await session.upload(for: request, fromFile: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.uploadFailed(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        default: return "audio/mpeg"
        }
    }

    private func localFileURL(for path: String) -> URL? {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func endpoint(_ path: String) -> URL {
        Config.apiBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

/// Per-task delegate that surfaces upload progress for pending rows.
private final class UploadProgressObserver: NSObject, URLSessionTaskDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
