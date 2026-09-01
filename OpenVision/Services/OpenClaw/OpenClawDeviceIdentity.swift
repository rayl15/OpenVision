import CryptoKit
import Foundation

/// Ed25519 device identity for the OpenClaw gateway handshake.
///
/// The gateway trusts loopback connections implicitly, so a client running on
/// the same machine as the gateway connects with a token alone. A connection
/// from another host — which is every connection from this phone — is granted
/// no write scope on a token by itself: `chat.send` comes back
/// "missing scope: operator.write" even though the handshake succeeded. It has
/// to present a signed device identity, which the gateway then holds as a
/// pairing request until it is approved once with:
///
///     openclaw devices approve <requestId>
///
/// The key is persisted in the Keychain so the phone presents the same device
/// on every launch; a fresh key each time would mean a new pairing request each
/// time, and a list full of stale devices.
enum OpenClawDeviceIdentity {

    private static let service = "ai.openclaw.openvision"
    private static let account = "openclaw-device-key"

    private static let key: Curve25519.Signing.PrivateKey = {
        if let stored = loadKey() { return stored }
        let fresh = Curve25519.Signing.PrivateKey()
        storeKey(fresh)
        return fresh
    }()

    /// Raw 32-byte public key, base64url — the form the gateway expects.
    static var publicKeyBase64URL: String { base64URL(key.publicKey.rawRepresentation) }

    /// sha256 of the raw public key, hex. The gateway derives this itself and
    /// compares, so it cannot be chosen freely.
    static var deviceId: String {
        SHA256.hash(data: key.publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The `device` object for the connect params. `nonce` must be the nonce
    /// from the server's `connect.challenge` event, and the signature covers
    /// the exact field order below — any deviation fails verification.
    static func deviceParams(
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        token: String,
        nonce: String
    ) -> [String: Any]? {
        let signedAt = Int(Date().timeIntervalSince1970 * 1000)
        let payload = [
            "v2", deviceId, clientId, clientMode, role,
            scopes.joined(separator: ","), String(signedAt), token, nonce,
        ].joined(separator: "|")

        guard let data = payload.data(using: .utf8),
              let signature = try? key.signature(for: data) else { return nil }

        return [
            "id": deviceId,
            "publicKey": publicKeyBase64URL,
            "signature": base64URL(signature),
            "signedAt": signedAt,
            "nonce": nonce,
        ]
    }

    // MARK: - Helpers

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func loadKey() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private static func storeKey(_ key: Curve25519.Signing.PrivateKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
