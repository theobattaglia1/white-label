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

    static let supabaseURL = "https://pojhfkamzteleogxxfqj.supabase.co"
    static let supabaseAnonKey = "sb_publishable_L0oZ8X6VDEfmR8WJg7Oifg_gdkmvEiT"

    static var useRealAuth: Bool {
        guard useRemoteAPI else { return false }
        let raw = ProcessInfo.processInfo.environment["PLAYBACK_USE_REAL_AUTH"]
            ?? ProcessInfo.processInfo.environment["WL_USE_REAL_AUTH"]
        if raw == "0" || raw == "false" { return false }
        return true
    }

    /// Base URL for share links. Defaults to the Render deployment.
    /// When playback.fm is live, change this to "https://playback.fm".
    static let appURL = "https://playback.allmyfriendsinc.com"

    static func shareURL(token: String) -> String {
        "\(appURL)/shared/\(token)"
    }
}
