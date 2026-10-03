// OpenVision - SettingsManager.swift
// Singleton manager for settings persistence with debounced auto-save.
// API keys and tokens are saved to the Keychain (SettingsSecrets), not settings.json.

import Foundation
import Combine

/// Manages app settings with JSON persistence and debounced saving
@MainActor
final class SettingsManager: ObservableObject {
    // MARK: - Singleton

    static let shared = SettingsManager()

    // MARK: - Published Properties

    /// Current app settings - changes trigger debounced save
    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue {
                scheduleSave()
            }
        }
    }

    // MARK: - Private Properties

    private let settingsURL: URL
    private var saveTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.5

    /// What the Keychain holds for each secret, so a save only writes the ones that changed.
    private var storedSecrets: [String: String] = [:]
    /// Secrets the Keychain couldn't be read for (before first unlock). Never written or deleted
    /// until a read succeeds, so a locked launch can't wipe them.
    private var unreadableSecrets: Set<String> = []
    /// Secrets whose Keychain write failed: kept in settings.json rather than lost.
    private var secretsKeptInFile: Set<String> = []
    /// Unreadable secrets the user reset: deleted, not restored, once the Keychain can be read.
    private var secretsToClear: Set<String> = []

    // MARK: - Callbacks

    /// Called when settings change (for live session updates)
    var onSettingsChanged: ((AppSettings) -> Void)?

    // MARK: - Initialization

    private init() {
        // Set up file URL
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        settingsURL = documentsURL.appendingPathComponent("settings.json")

        // Load existing settings or create defaults, then the secrets from the Keychain
        let fileSettings = Self.loadSettings(from: settingsURL)
        var keychain: [String: SettingsSecrets.Stored] = [:]
        for (account, _) in SettingsSecrets.fields { keychain[account] = SettingsSecrets.read(account) }
        let merged = SettingsSecrets.merge(file: fileSettings, keychain: keychain)
        settings = merged.settings
        unreadableSecrets = merged.unreadable
        for (account, stored) in keychain { if case .value(let value) = stored { storedSecrets[account] = value } }

        print("[SettingsManager] Initialized with settings from: \(settingsURL.path)")

        // A settings.json from an older build still has keys in plain text: move them now.
        if SettingsSecrets.fields.contains(where: { !fileSettings[keyPath: $0.keyPath].isEmpty }) {
            print("[SettingsManager] Moving API keys from settings.json to the Keychain")
            saveNow()
        }
    }

    // MARK: - Public Methods

    /// Save settings immediately (use on app background/disappear)
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        performSave()
    }

    /// Reset settings to defaults
    func resetToDefaults() {
        secretsToClear = unreadableSecrets
        settings = AppSettings()
        saveNow()
    }

    // MARK: - Memory Management

    /// Add or update a memory
    func setMemory(key: String, value: String) {
        settings.memories[key] = value
    }

    /// Delete a memory
    func deleteMemory(key: String) {
        settings.memories.removeValue(forKey: key)
    }

    /// Rename a memory key
    func renameMemory(oldKey: String, newKey: String) {
        guard let value = settings.memories[oldKey] else { return }
        settings.memories.removeValue(forKey: oldKey)
        settings.memories[newKey] = value
    }

    // MARK: - Private Methods

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // NOTE: was UInt64(debounceInterval) which is UInt64(0.5) == 0 — no delay. Multiply into
            // nanoseconds first so the debounce actually coalesces rapid edits (e.g. typing a key).
            let seconds = self?.debounceInterval ?? 0.5
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performSave()
            self?.onSettingsChanged?(self?.settings ?? AppSettings())
        }
    }

    private func performSave() {
        saveSecrets()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // A secret typed while the Keychain was unreadable stays in the file until it isn't.
            let pending = unreadableSecrets.filter { account in
                SettingsSecrets.fields.contains { $0.account == account && !settings[keyPath: $0.keyPath].isEmpty }
            }
            let data = try encoder.encode(SettingsSecrets.forFile(settings, keepInFile: secretsKeptInFile.union(pending)))
            try data.write(to: settingsURL, options: .atomic)
            print("[SettingsManager] Settings saved")
        } catch {
            print("[SettingsManager] Error saving settings: \(error)")
        }
    }

    /// Write the secrets that changed to the Keychain.
    private func saveSecrets() {
        for (account, keyPath) in SettingsSecrets.fields {
            if unreadableSecrets.contains(account) {
                // Try again: the phone may have been unlocked since launch.
                switch SettingsSecrets.read(account) {
                case .unreadable:
                    continue
                case .value(let stored):
                    storedSecrets[account] = stored
                    // Reset since launch: the write below deletes it instead.
                    if settings[keyPath: keyPath].isEmpty && !secretsToClear.contains(account) {
                        settings[keyPath: keyPath] = stored
                    }
                case .none:
                    break
                }
                unreadableSecrets.remove(account)
                secretsToClear.remove(account)
            }
            let value = settings[keyPath: keyPath]
            guard storedSecrets[account, default: ""] != value else {
                // The Keychain already has it (e.g. changed back after a failed write).
                secretsKeptInFile.remove(account)
                continue
            }
            if SettingsSecrets.write(value, account: account) {
                storedSecrets[account] = value
                secretsKeptInFile.remove(account)
            } else {
                secretsKeptInFile.insert(account)
            }
        }
    }

    private static func loadSettings(from url: URL) -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            print("[SettingsManager] No settings file, using defaults")
            return createDefaultSettings()
        }

        // Strict decode first — succeeds when every field is present.
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            print("[SettingsManager] Loaded settings from file")
            return settings
        }

        // Lenient fallback. Synthesized Codable throws on ANY missing key, so a settings.json
        // written by an older build (before a field was added) would otherwise reset EVERYTHING to
        // defaults — silently wiping saved API keys. Instead, overlay the on-disk values onto the
        // defaults' JSON (so present keys keep the user's value, missing keys fall back to default)
        // and decode the merge. This makes adding new settings fields non-destructive.
        let defaults = createDefaultSettings()
        if let defaultsData = try? JSONEncoder().encode(defaults),
           var merged = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any],
           let onDisk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in onDisk { merged[key] = value }   // on-disk value wins where present
            if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: mergedData) {
                print("[SettingsManager] Loaded settings via lenient merge (older file, missing fields filled)")
                return settings
            }
        }

        print("[SettingsManager] Could not decode settings even leniently — using defaults")
        return defaults
    }

    private static func createDefaultSettings() -> AppSettings {
        var settings = AppSettings()

        // Apply any build-time defaults from Config
        if !Config.defaultOpenClawGatewayURL.isEmpty {
            settings.openClawGatewayURL = Config.defaultOpenClawGatewayURL
        }
        if !Config.defaultOpenClawAuthToken.isEmpty {
            settings.openClawAuthToken = Config.defaultOpenClawAuthToken
        }
        if !Config.defaultGeminiAPIKey.isEmpty {
            settings.geminiAPIKey = Config.defaultGeminiAPIKey
        }

        return settings
    }
}
