import Foundation

/// Runtime configuration. Edit `defaultAPIBaseURL` for production, or pass
/// `WL_API_BASE_URL` as a process environment variable for one-off testing.
enum PMWConfig {
    /// Where the WL API + static audio live. Used by both PMWAudioEngine
    /// (for /seed-audio/*) and PMWAPIClient (for /rooms, /songs, /notes).
    static var apiBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["WL_API_BASE_URL"],
           let url = URL(string: raw) { return url }
        return URL(string: defaultAPIBaseURL)!
    }

    /// Default API URL.
    ///
    /// - In Simulator on the dev machine, point at the dev API + Vite web:
    ///   `http://127.0.0.1:5180` (Vite serves /seed-audio from /public,
    ///   and you can run a reverse-proxy or hit the API separately).
    ///
    /// - On a real device on the same Wi-Fi as your Mac, replace 127.0.0.1
    ///   with the Mac's LAN IP.
    ///
    /// - In production (TestFlight / App Store), set this to your Render URL,
    ///   e.g. `https://white-label-api.onrender.com`.
    static let defaultAPIBaseURL = "http://127.0.0.1:5180"

    /// When true, PMWStore loads from PMWAPIClient. When false, it uses
    /// PMWSampleData and the user can demo the UI offline.
    static var useRemoteAPI: Bool {
        ProcessInfo.processInfo.environment["WL_USE_REMOTE_API"] == "1"
    }

    /// The dev user id sent as the `x-user-id` header. Stand-in until real
    /// Supabase auth is wired (see HANDOFF.md).
    static let devUserId = "usr-theo"
}
