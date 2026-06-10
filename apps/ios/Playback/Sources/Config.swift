import Foundation

/// App-wide constants. Update APP_URL when a custom domain is configured.
enum Config {
    static var apiBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["PLAYBACK_API_BASE_URL"]
            ?? ProcessInfo.processInfo.environment["WL_API_BASE_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://white-label-api-6mnt.onrender.com")!
    }

    static var useRemoteAPI: Bool {
        let raw = ProcessInfo.processInfo.environment["PLAYBACK_USE_REMOTE_API"]
            ?? ProcessInfo.processInfo.environment["WL_USE_REMOTE_API"]
        return raw != "0" && raw != "false"
    }

    static let defaultWorkspaceID = "wsp-amf-private"
    static let devUserID = "usr-theo"
    static let appGroupIdentifier = "group.inc.allmyfriends.playback"

    static let supabaseURL = "https://pojhfkamzteleogxxfqj.supabase.co"
    static let supabaseAnonKey = "sb_publishable_L0oZ8X6VDEfmR8WJg7Oifg_gdkmvEiT"

    static var useRealAuth: Bool {
        guard useRemoteAPI else { return false }
        let raw = ProcessInfo.processInfo.environment["PLAYBACK_USE_REAL_AUTH"]
            ?? ProcessInfo.processInfo.environment["WL_USE_REAL_AUTH"]
        if let raw {
            return raw != "0" && raw != "false"
        }
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Base URL for recipient web links. Defaults to the deployed web surface,
    /// but can be pointed at localhost for Simulator QA.
    static var appURL: String {
        ProcessInfo.processInfo.environment["PLAYBACK_APP_URL"]
            ?? ProcessInfo.processInfo.environment["WL_APP_URL"]
            ?? "https://playback.allmyfriendsinc.com"
    }

    static func shareURL(token: String) -> String {
        "\(appURL)/shared/\(token)"
    }

    static func firstListenURL(token: String) -> String {
        "\(appURL)/listen/\(token)"
    }

    static func listeningRoomURL(token: String) -> String {
        "\(appURL)/room/\(token)"
    }
}
