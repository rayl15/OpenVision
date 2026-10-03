// OpenVision - OAuthTokenStore.swift
// Keychain persistence for subscription sign-ins, plus refresh-on-demand.
//
// These are long-lived refresh tokens for the user's whole subscription account, so they live in
// the Keychain (API keys too, via SettingsSecrets). Accessible after first unlock (not "when
// unlocked") so a reply can still go out while the phone is locked in a pocket.
//
// Refreshes are single-flight per provider: providers rotate the refresh token on use, so two
// concurrent refreshes with the same token would race and the loser would sign the user out.

import Foundation
import Security

final class OAuthTokenStore: @unchecked Sendable {

    static let shared = OAuthTokenStore()

    private let service = (Bundle.main.bundleIdentifier ?? "openvision") + ".oauth"
    private let lock = NSLock()
    private var cache: [String: OAuthCredentials] = [:]
    private var loaded: Set<String> = []
    private var refreshes: [String: Task<OAuthCredentials, Error>] = [:]

    private init() {}

    // MARK: - Read / write

    func credentials(for provider: OAuthProvider) -> OAuthCredentials? {
        lock.lock(); defer { lock.unlock() }
        return cachedLocked(provider.id)
    }

    func isSignedIn(_ provider: OAuthProvider) -> Bool {
        credentials(for: provider) != nil
    }

    /// Store a new sign-in. Any refresh still in flight belongs to the previous session: drop it,
    /// so its result can't overwrite these credentials or sign them out.
    func save(_ credentials: OAuthCredentials, for provider: OAuthProvider) {
        lock.withLock {
            refreshes[provider.id]?.cancel()
            refreshes[provider.id] = nil
            storeLocked(credentials, account: provider.id)
        }
    }

    /// Cache + Keychain write. Caller holds `lock`.
    private func storeLocked(_ credentials: OAuthCredentials, account: String) {
        cache[account] = credentials
        loaded.insert(account)
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        // Update in place (atomic), adding only when there's nothing to update: delete-then-add
        // would leave no item at all if the add failed.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery(account).merging(attributes) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess { NSLog("[OAuth] keychain save failed for %@: %d", account, status) }
    }

    func signOut(_ provider: OAuthProvider) {
        lock.lock(); defer { lock.unlock() }
        cache[provider.id] = nil
        loaded.insert(provider.id)
        refreshes[provider.id]?.cancel()
        refreshes[provider.id] = nil
        SecItemDelete(baseQuery(provider.id) as CFDictionary)
    }

    // MARK: - Fresh access token

    /// Credentials with a usable access token, refreshing first if expired (or if `force`, e.g.
    /// after the API rejected the current token). A rejected refresh token signs the user out
    /// and throws `.authorizationExpired`; a network failure keeps the sign-in for a retry.
    func freshCredentials(for provider: OAuthProvider, force: Bool = false) async throws -> OAuthCredentials {
        // Decide under the lock (withLock: a plain lock()/unlock() pair isn't allowed across an
        // async function), then await outside it.
        enum Next { case current(OAuthCredentials), refresh(Task<OAuthCredentials, Error>), signedOut }
        let next: Next = lock.withLock {
            guard let current = cachedLocked(provider.id) else { return .signedOut }
            if !force && !current.isExpired() { return .current(current) }
            if let inflight = refreshes[provider.id] { return .refresh(inflight) }
            let task = Task { try await OAuthClient.refresh(current, provider: provider) }
            refreshes[provider.id] = task
            return .refresh(task)
        }

        let task: Task<OAuthCredentials, Error>
        switch next {
        case .signedOut: throw OAuthError.authorizationExpired
        case .current(let credentials): return credentials
        case .refresh(let refresh): task = refresh
        }

        do {
            let refreshed = try await task.value
            // Commit under the same lock that guards `refreshes`, and only while this refresh is
            // still the in-flight one. Clearing the entry first would let a caller in the gap see
            // the old token and refresh with an already-rotated refresh token (→ invalid_grant →
            // signed out); and a sign-out that happened meanwhile must not be undone. Other
            // waiters on the same task find it committed and get the cached credentials.
            return try lock.withLock {
                if refreshes[provider.id] == task {
                    refreshes[provider.id] = nil
                    storeLocked(refreshed, account: provider.id)
                    NSLog("[OAuth] refreshed %@ access token", provider.id)
                    return refreshed
                }
                if let current = cachedLocked(provider.id) { return current }
                throw OAuthError.authorizationExpired   // signed out while refreshing
            }
        } catch {
            let ownedRefresh = lock.withLock { () -> Bool in
                guard refreshes[provider.id] == task else { return false }
                refreshes[provider.id] = nil
                return true
            }
            if ownedRefresh, (error as? OAuthError) == .authorizationExpired { signOut(provider) }
            throw error
        }
    }

    // MARK: - Keychain

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Cache-through Keychain read. Caller holds `lock`.
    private func cachedLocked(_ account: String) -> OAuthCredentials? {
        if loaded.contains(account) { return cache[account] }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Only a definitive answer is cached. A transient error, e.g. errSecInteractionNotAllowed
        // when the app is relaunched in the background before first unlock, must be retried
        // later instead of reporting a still-valid sign-in as signed out for the whole session.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            NSLog("[OAuth] keychain read for %@ failed: %d (will retry)", account, status)
            return nil
        }
        loaded.insert(account)
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(OAuthCredentials.self, from: data) else {
            return nil
        }
        cache[account] = credentials
        return credentials
    }
}
