// OpenVision - CloudTTSFallbackTests.swift
// A cloud-voice sentence that fails is spoken in the Apple voice, in its place in the reply (#62).
// Uses a fake provider that returns short silent WAV clips and fails chosen sentences; the audio
// really plays, so these run on a device or simulator with audio output.

import XCTest
@testable import OpenVision

@MainActor
final class CloudTTSFallbackTests: XCTestCase {

    private let reply = "Sentence one. Sentence two. Sentence three. Sentence four."

    func testFailedSentenceIsSpokenInTheAppleVoiceInOrder() async throws {
        let events = try await play(reply, failing: ["two"])
        XCTAssertEqual(events.map(\.0), ["Sentence one.", "Sentence two.", "Sentence three.", "Sentence four."])
        XCTAssertEqual(events.map(\.1), [false, true, false, false], "only sentence two in the Apple voice")
    }

    func testTwoFailuresInARowMoveTheRestToTheAppleVoice() async throws {
        let events = try await play(reply, failing: ["two", "three"])
        XCTAssertEqual(events.map(\.0), ["Sentence one.", "Sentence two.", "Sentence three.", "Sentence four."])
        XCTAssertEqual(events.map(\.1), [false, true, true, true], "no alternating voices once offline")
    }

    func testAfterTwoFailuresTheCloudIsNotAskedAgain() async throws {
        let requests = RequestLog()
        let service = CloudTTSService(provider: Self.fakeProvider(failing: ["two", "three"], log: requests))
        await service.speak("One. Sentence two. Sentence three. Four. Five. Six.")
        try await waitUntilQuiet(service)
        XCTAssertFalse(requests.texts.contains("Six."), "sentence six was never sent: \(requests.texts)")
    }

    func testStopDuringTheFallbackStopsEverything() async throws {
        let service = CloudTTSService(provider: Self.fakeProvider(failing: ["two"]))
        var events: [(String, Bool)] = []
        service.onSentenceStarted = { sentence, apple in
            events.append((sentence, apple))
            if apple { service.stop() }   // barge-in while the Apple voice speaks sentence two
        }
        await service.speak(reply)
        try await waitUntilQuiet(service)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(events.map(\.0), ["Sentence one.", "Sentence two."])
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(service.fallbackUtterances, 0, "the Apple sentence must not start after the stop")
    }

    func testVoicePreviewDoesNotFallBack() async throws {
        let service = CloudTTSService(provider: Self.fakeProvider(failing: ["one"]))
        var events: [(String, Bool)] = []
        service.onSentenceStarted = { events.append(($0, $1)) }
        await service.speak("Sentence one.", voice: "test")
        try await waitUntilQuiet(service)
        XCTAssertTrue(events.isEmpty, "a failed preview shows the error instead")
        XCTAssertNotNil(service.lastFailure)
    }

    // MARK: - Helpers

    private func play(_ text: String, failing: Set<String>) async throws -> [(String, Bool)] {
        let service = CloudTTSService(provider: Self.fakeProvider(failing: failing))
        var events: [(String, Bool)] = []
        service.onSentenceStarted = { events.append(($0, $1)) }
        await service.speak(text)
        try await waitUntilQuiet(service)
        return events
    }

    private func waitUntilQuiet(_ service: CloudTTSService, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while service.isSpeaking {
            guard Date() < deadline else { return XCTFail("still speaking after \(timeout)s") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Fails any sentence containing one of `failing` like a dropped connection; others get a
    /// short silent clip.
    private final class RequestLog { var texts: [String] = [] }

    private static func fakeProvider(failing: Set<String>, log: RequestLog? = nil) -> CloudVoiceProvider {
        CloudVoiceProvider(
            name: "FakeTTS",
            isReady: { true },
            selectedVoice: { "test" },
            synthesize: { text, _ in
                log?.texts.append(text)
                if failing.contains(where: { text.lowercased().contains($0) }) { throw URLError(.timedOut) }
                let response = HTTPURLResponse(url: URL(string: "https://tts.test")!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                return (silentWAV(seconds: 0.15), response)
            }
        )
    }

    /// 16-bit mono PCM WAV at 24 kHz, like the providers return.
    private static func silentWAV(seconds: Double, sampleRate: Int = 24_000) -> Data {
        let samples = Int(Double(sampleRate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }
}
