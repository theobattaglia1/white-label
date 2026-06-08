import Foundation
import Security

/// Minimal Keychain helper for persisting a single PMWAuthSession.
/// Uses kSecClassGenericPassword with service "playback-auth".
/// No third-party wrapper — raw SecItem* calls only.
enum PMWKeychain {
    private static let service = "playback-auth"
    private static let account = "pmw-session"

    // MARK: - Public API ------------------------------------------------------

    /// Persist (or replace) a session. Returns `true` on success, `false` on
    /// encode or SecItemAdd failure. Caller should surface a warning when
    /// false — the worst outcome is the user re-signs-in on next launch.
    @discardableResult
    static func save(_ session: PMWAuthSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }

        // Delete any existing item first; SecItemUpdate is finicky with
        // duplicate queries, so delete-then-add is the safe pattern.
        delete()

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecValueData:        data,
            // Accessible after first unlock — survives a reboot/background
            // without requiring the screen to be on, matching typical auth
            // needs. NOT accessible after device restart until user unlocks.
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Load the stored session, or nil if none exists or data is corrupt.
    static func load() -> PMWAuthSession? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let session = try? JSONDecoder().decode(PMWAuthSession.self, from: data)
        else { return nil }
        return session
    }

    /// Remove the stored session. Silent on failure.
    static func delete() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
