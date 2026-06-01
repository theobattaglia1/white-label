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
    /// Defaults to the live Render deployment so a fresh checkout / TestFlight
    /// build "just works". For local development, override with the
    /// `WL_API_BASE_URL` scheme env var (Product → Scheme → Edit Scheme →
    /// Run → Arguments → Environment Variables), e.g.:
    ///
    ///   - Simulator on dev machine:  `http://127.0.0.1:4317`
    ///   - Real device on same Wi-Fi: `http://<mac-lan-ip>:4317`
    static let defaultAPIBaseURL = "https://white-label-api-6mnt.onrender.com"

    /// When true, PMWStore loads from PMWAPIClient. When false, it uses
    /// PMWSampleData and the user can demo the UI offline.
    /// Defaults to true so the production build pulls live data; set
    /// `WL_USE_REMOTE_API=0` in the scheme to force the offline sample
    /// dataset (useful for design reviews and screenshots).
    static var useRemoteAPI: Bool {
        let raw = ProcessInfo.processInfo.environment["WL_USE_REMOTE_API"]
        if raw == "0" || raw == "false" { return false }
        return true
    }

    /// The dev user id sent as the `x-user-id` header. Kept as legacy
    /// fallback — sent alongside Bearer once real auth is active.
    static let devUserId = "usr-theo"

    // MARK: - Supabase --------------------------------------------------------

    /// Supabase project URL. Same project used by the web app.
    static let supabaseURL = "https://pojhfkamzteleogxxfqj.supabase.co"

    /// Publishable / anon key — safe to ship in the client (same key the web
    /// app ships in the browser bundle). Does NOT grant any privileged access;
    /// Row-Level Security on the database enforces real permissions.
    static let supabaseAnonKey = "sb_publishable_L0oZ8X6VDEfmR8WJg7Oifg_gdkmvEiT"

    /// When true, the app requires a real Supabase sign-in after the biometric
    /// gate and injects `Authorization: Bearer <token>` on every API request.
    ///
    /// Default: FALSE — the dev/sample-data loop is completely unchanged.
    /// Enable via the `WL_USE_REAL_AUTH=1` environment variable on the scheme
    /// (Product → Scheme → Edit Scheme → Run → Arguments → Environment
    /// Variables). Release builds that need auth should set this at build time
    /// or via a scheme.
    ///
    /// NOTE: Server-side JWT enforcement is NOT part of this change. The server
    /// still keys off `x-user-id`; Bearer is client plumbing that is wired and
    /// ready but not yet enforced server-side.
    static var useRealAuth: Bool {
        let raw = ProcessInfo.processInfo.environment["WL_USE_REAL_AUTH"]
        return raw == "1" || raw == "true"
    }
}
