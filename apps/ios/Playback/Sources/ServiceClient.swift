import Foundation
import AVFoundation

enum ServiceError: Error, LocalizedError {
    case emptyResponse
    case requestFailed(String)
    case uploadFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "The service returned an empty response."
        case .requestFailed(let message): return message
        case .uploadFailed(let status, let detail): return "Upload failed (\(status)): \(detail)"
        }
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

    func uploadNewSong(
        audioURL: URL,
        title: String,
        artist: String,
        project: String,
        versionLabel: String,
        durationMs: Int,
        artworkPath: String?
    ) async throws -> APIFinalizeNewSong {
        let workspaceID = await resolvedWorkspaceID(nil)
        let filename = audioURL.lastPathComponent
        let audioContentType = contentType(for: audioURL)
        let signed = try await post(
            "/storage/sign-upload",
            body: ["filename": filename, "contentType": audioContentType, "workspaceExternalId": workspaceID],
            as: APISignUpload.self
        )

        try await uploadFile(audioURL, to: signed.uploadUrl, contentType: audioContentType)

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

    private func delete<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(method: "DELETE", path: path, body: nil, as: type)
    }

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
        if Config.useRealAuth {
            guard let token = await PlaybackAuthSession.shared.validAccessToken() else {
                throw ServiceError.requestFailed("Sign in again to continue.")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        } else {
            request.setValue(Config.devUserID, forHTTPHeaderField: "x-user-id")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.requestFailed("No HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data)["error"])
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ServiceError.requestFailed(message)
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let error = envelope.error { throw ServiceError.requestFailed(error) }
        guard let value = envelope.data else { throw ServiceError.emptyResponse }
        return value
    }

    private func uploadFile(_ url: URL, to signedURL: String, contentType: String) async throws {
        guard let destination = URL(string: signedURL) else {
            throw ServiceError.requestFailed("Upload URL was invalid.")
        }
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (_, response) = try await session.upload(for: request, fromFile: url)
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
