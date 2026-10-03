// OpenVision - SettingsSecretsTests.swift
// API keys move from settings.json to the Keychain without being lost on the way.

import XCTest
@testable import OpenVision

final class SettingsSecretsTests: XCTestCase {

    func testEverySecretFieldIsCovered() {
        let accounts = SettingsSecrets.fields.map(\.account)
        XCTAssertEqual(Set(accounts).count, accounts.count, "one Keychain account per field")
        XCTAssertTrue(accounts.contains("hermesAPIKey"))
        XCTAssertTrue(accounts.contains("telemetryPassword"))
    }

    func testFileIsWrittenWithoutSecrets() throws {
        var settings = AppSettings()
        settings.hermesAPIKey = "hermes-key"
        settings.openAIAPIKey = "sk-test"
        settings.openClawGatewayURL = "wss://gateway.example"
        let json = String(decoding: try JSONEncoder().encode(SettingsSecrets.forFile(settings, keepInFile: [])), as: UTF8.self)
        XCTAssertFalse(json.contains("hermes-key") || json.contains("sk-test"))
        XCTAssertTrue(json.contains("gateway.example"), "other settings stay in the file")
    }

    func testAFailedKeychainWriteKeepsTheKeyInTheFile() {
        var settings = AppSettings()
        settings.grokAPIKey = "xai-key"
        settings.geminiAPIKey = "gemini-key"
        let file = SettingsSecrets.forFile(settings, keepInFile: ["grokAPIKey"])
        XCTAssertEqual(file.grokAPIKey, "xai-key")
        XCTAssertEqual(file.geminiAPIKey, "")
    }

    func testLoadingTakesKeysFromTheKeychain() {
        let merged = SettingsSecrets.merge(file: AppSettings(), keychain: ["hermesAPIKey": .value("from-keychain")])
        XCTAssertEqual(merged.settings.hermesAPIKey, "from-keychain")
        XCTAssertTrue(merged.unreadable.isEmpty)
    }

    func testAnOlderFilesKeyWinsSoItCanBeMoved() {
        var file = AppSettings()
        file.tavilyAPIKey = "from-old-file"
        let merged = SettingsSecrets.merge(file: file, keychain: ["tavilyAPIKey": .value("stale")])
        XCTAssertEqual(merged.settings.tavilyAPIKey, "from-old-file")
    }

    func testAnUnreadableKeychainIsRememberedNotTreatedAsEmpty() {
        let merged = SettingsSecrets.merge(file: AppSettings(), keychain: ["openAIAPIKey": .unreadable])
        XCTAssertEqual(merged.settings.openAIAPIKey, "")
        XCTAssertEqual(merged.unreadable, ["openAIAPIKey"], "so a save can't delete the stored key")
    }

    func testKeychainRoundTrip() {
        // A test-only account, so the app's real keys on the device are never touched.
        let account = "test-\(UUID().uuidString)"
        defer { SettingsSecrets.write("", account: account) }
        XCTAssertEqual(SettingsSecrets.read(account), .none)
        XCTAssertTrue(SettingsSecrets.write("first", account: account))
        XCTAssertEqual(SettingsSecrets.read(account), .value("first"))
        XCTAssertTrue(SettingsSecrets.write("second", account: account))
        XCTAssertEqual(SettingsSecrets.read(account), .value("second"))
        XCTAssertTrue(SettingsSecrets.write("", account: account), "clearing a key deletes it")
        XCTAssertEqual(SettingsSecrets.read(account), .none)
    }
}
