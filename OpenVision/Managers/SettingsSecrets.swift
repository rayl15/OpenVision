// OpenVision - SettingsSecrets.swift
// API keys and tokens from AppSettings, kept in the Keychain instead of settings.json.
//
// AppSettings still holds them in memory, so the views and services read and write them as before.
// Only persistence changes: SettingsManager writes them here and saves settings.json with those
// fields blank. A settings.json from an older build still has them in plain text; loading it
// moves them here and the next save blanks them in the file.

import Foundation
import Security

enum SettingsSecrets {

    /// Every secret field, by its Keychain account.
    static let fields: [(account: String, keyPath: WritableKeyPath<AppSettings, String>)] = [
        ("openClawAuthToken", \.openClawAuthToken),
        ("geminiAPIKey", \.geminiAPIKey),
        ("openAIAPIKey", \.openAIAPIKey),
        ("grokAPIKey", \.grokAPIKey),
        ("hermesAPIKey", \.hermesAPIKey),
        ("tavilyAPIKey", \.tavilyAPIKey),
        ("telemetryToken", \.telemetryToken),
        ("telemetryPassword", \.telemetryPassword),
    ]

    /// What the Keychain said about one account: a value, nothing stored, or no answer (it can't
    /// be read before the phone's first unlock).
    enum Stored: Equatable {
        case value(String)
        case none
        case unreadable
    }

    /// The settings to use after loading: a value still in the file (an older build's) wins, since
    /// it's what the user last set; otherwise the Keychain's. Also returns the accounts that
    /// couldn't be read, which mustn't be overwritten or deleted until they can.
    static func merge(file: AppSettings, keychain: [String: Stored]) -> (settings: AppSettings, unreadable: Set<String>) {
        var settings = file
        var unreadable: Set<String> = []
        for (account, keyPath) in fields where file[keyPath: keyPath].isEmpty {
            switch keychain[account] ?? .none {
            case .value(let value): settings[keyPath: keyPath] = value
            case .none: break
            case .unreadable: unreadable.insert(account)
            }
        }
        return (settings, unreadable)
    }

    /// The settings as written to settings.json: secrets blank, except any whose Keychain write
    /// failed, which stay in the file rather than be lost.
    static func forFile(_ settings: AppSettings, keepInFile: Set<String>) -> AppSettings {
        var stripped = settings
        for (account, keyPath) in fields where !keepInFile.contains(account) {
            stripped[keyPath: keyPath] = ""
        }
        return stripped
    }

    // MARK: - Keychain

    private static let service = (Bundle.main.bundleIdentifier ?? "openvision") + ".settings"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Stored {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .none }
            return value.isEmpty ? .none : .value(value)
        case errSecItemNotFound:
            return .none
        default:
            NSLog("[Secrets] keychain read for %@ failed: %d", account, status)
            return .unreadable
        }
    }

    /// Store `value`, or delete the item when it's empty. Returns whether the Keychain took it.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        if value.isEmpty {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        // Accessible after first unlock, like the sign-in tokens: replies still work in a pocket.
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery(account).merging(attributes) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess { NSLog("[Secrets] keychain save failed for %@: %d", account, status) }
        return status == errSecSuccess
    }
}
