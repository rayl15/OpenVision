// OpenVision - GrokTests.swift
// SuperGrok sign-in config, the OIDC discovery host check, the Grok model list filter, and the
// Grok speech engine's voice list + WAV decoding.

import AVFoundation
import XCTest
@testable import OpenVision

final class GrokTests: XCTestCase {

    private let provider = GrokService.provider

    func testRedirectMatchesGrokCLIClient() {
        XCTAssertEqual(provider.redirectURI, "http://127.0.0.1:56121/callback")
        XCTAssertTrue(provider.scope.contains("api:access"), "api:access is what lets the token call api.x.ai")
    }

    // MARK: - Discovery endpoints

    func testDiscoveryAcceptsXAIHostAndSubdomains() {
        XCTAssertNotNil(OAuthClient.trustedEndpoint("https://auth.x.ai/oauth2/token", provider))
        XCTAssertNotNil(OAuthClient.trustedEndpoint("https://x.ai/oauth2/token", provider))
    }

    func testDiscoveryRejectsOtherHostsAndPlainHTTP() {
        XCTAssertNil(OAuthClient.trustedEndpoint("http://auth.x.ai/oauth2/token", provider))
        XCTAssertNil(OAuthClient.trustedEndpoint("https://evil.com/oauth2/token", provider))
        XCTAssertNil(OAuthClient.trustedEndpoint("https://auth.x.ai.evil.com/token", provider))
        XCTAssertNil(OAuthClient.trustedEndpoint("https://notx.ai/token", provider))
        XCTAssertNil(OAuthClient.trustedEndpoint(nil, provider))
    }

    func testProvidersWithoutDiscoveryResolveToThemselves() async {
        let chatGPT = await OAuthClient.resolved(ChatGPTSubscription.provider)
        XCTAssertEqual(chatGPT.tokenURL, ChatGPTSubscription.provider.tokenURL)
    }

    // MARK: - Models

    func testModelsSkipNonChatModels() throws {
        let json = try JSONSerialization.data(withJSONObject: ["data": [
            ["id": "grok-4.20-0309-non-reasoning"], ["id": "grok-4.7"],
            ["id": "grok-imagine-image"], ["id": "grok-imagine-video-1.5"],
            ["id": "grok-voice-think-fast-2.0"], ["id": "grok-build-0.1"],
        ]])
        XCTAssertEqual(GrokService.parseModels(json), ["grok-4.20-0309-non-reasoning", "grok-4.7"])
    }

    // MARK: - Speech

    func testVoicesParse() throws {
        let json = try JSONSerialization.data(withJSONObject: ["voices": [
            ["voice_id": "ara", "name": "Ara", "language": "multilingual", "gender": "female"],
            ["name": "missing id"],
        ]])
        let voices = CloudTTSService.parseGrokVoices(json)
        XCTAssertEqual(voices.map(\.id), ["ara"])
        XCTAssertEqual(voices.first?.gender, "female")
    }

    func testDecodesWAVLikeXAIReturns() throws {
        // 24 kHz mono 16-bit PCM — the format xAI's TTS returns for codec "wav".
        let samples: [Int16] = (0..<2400).map { Int16(sin(Double($0) / 10) * 8000) }
        let buffer = try XCTUnwrap(CloudTTSService.decodeWAV(wav(samples, sampleRate: 24000)))
        XCTAssertEqual(buffer.frameLength, 2400)
        XCTAssertEqual(buffer.format.sampleRate, 24000)
        XCTAssertEqual(buffer.format.channelCount, 1)
    }

    func testXAIStringErrorsAreReadable() {
        let data = Data(#"{"code":"Client specified an invalid argument","error":"Incorrect API key provided"}"#.utf8)
        XCTAssertEqual(CloudChat.errorMessage(from: data), "Incorrect API key provided")
    }

    // MARK: - Helpers

    private func wav(_ samples: [Int16], sampleRate: UInt32) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let dataSize = UInt32(samples.count * 2)
        var d = Data("RIFF".utf8) + le(UInt32(36) + dataSize) + Data("WAVE".utf8)
        d += Data("fmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        d += le(sampleRate) + le(sampleRate * 2) + le(UInt16(2)) + le(UInt16(16))
        d += Data("data".utf8) + le(dataSize)
        for s in samples { d += le(s) }
        return d
    }
}
