// OpenVision - LocalAgentRouteTests.swift
// The JSON-in-text router that turns a small model's output into face actions, web searches,
// or spoken answers. The generate closure is stubbed — no model, no network, no tools executed.
// (Native-tool JSON is intentionally NOT covered here: routing it would execute the real tool.)

import XCTest
@testable import OpenVision

final class LocalAgentRouteTests: XCTestCase {

    /// Route with a canned model output.
    private func route(_ modelOutput: String?, command: String = "test command") async -> LocalAgent.RouteResult {
        await LocalAgent.route(command, history: []) { _, _, _ in modelOutput }
    }

    // MARK: - Face actions

    func testFaceRemember() async {
        let result = await route(#"{"face":"remember","name":"Sara"}"#)
        guard case .face(let intent) = result else {
            return XCTFail("expected .face, got \(result)")
        }
        XCTAssertEqual(intent.action, "remember")
        XCTAssertEqual(intent.name, "Sara")
    }

    func testFaceIdentifyWithEmptyName() async {
        let result = await route(#"{"face":"identify","name":""}"#)
        guard case .face(let intent) = result else {
            return XCTFail("expected .face, got \(result)")
        }
        XCTAssertEqual(intent.action, "identify")
        XCTAssertEqual(intent.name, "")
    }

    func testUnknownFaceActionFallsThroughToAnswer() async {
        let result = await route(#"{"face":"dance","name":"x"}"#)
        guard case .answer = result else {
            return XCTFail("unknown face action must not become a face intent")
        }
    }

    // MARK: - Web search

    func testWebSearch() async {
        let result = await route(#"{"tool":"web_search","query":"weather in Tokyo"}"#)
        guard case .webSearch(let query) = result else {
            return XCTFail("expected .webSearch, got \(result)")
        }
        XCTAssertEqual(query, "weather in Tokyo")
    }

    func testWebSearchEmptyQueryFallsThroughToAnswer() async {
        let result = await route(#"{"tool":"web_search","query":""}"#)
        guard case .answer = result else {
            return XCTFail("empty query must not trigger a search")
        }
    }

    // MARK: - Plain answers & robustness

    func testPlainAnswerPassesThroughTrimmed() async {
        let result = await route("  The capital of France is Paris.  \n")
        guard case .answer(let text) = result else {
            return XCTFail("expected .answer, got \(result)")
        }
        XCTAssertEqual(text, "The capital of France is Paris.")
    }

    func testJSONEmbeddedInChatterStillParses() async {
        // Small models often wrap the JSON in prose; the router scans first "{" to last "}".
        let result = await route(#"Sure! Here you go: {"tool":"web_search","query":"bitcoin price"} Hope that helps."#)
        guard case .webSearch(let query) = result else {
            return XCTFail("expected .webSearch from embedded JSON, got \(result)")
        }
        XCTAssertEqual(query, "bitcoin price")
    }

    func testMalformedJSONFallsBackToAnswer() async {
        let output = #"{"face": broken json"#
        let result = await route(output)
        guard case .answer(let text) = result else {
            return XCTFail("malformed JSON must fall back to a spoken answer")
        }
        XCTAssertEqual(text, output)
    }

    func testNilGenerationYieldsApologyAnswer() async {
        let result = await route(nil)
        guard case .answer(let text) = result else {
            return XCTFail("expected .answer on generation failure")
        }
        XCTAssertFalse(text.isEmpty)
    }

    // MARK: - relativeMinutes: the deterministic "15 minutes from now" guard
    // (Small models turn relative requests into wrong absolute clock times; the utterance is
    // ground truth, so the router parses N itself and overrides the model's time args.)

    func testRelativeMinutesMarkerBefore() {
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "Set up a focus event in 15 minutes"), 15)
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "remind me after 5 min"), 5)
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "in 2 hours please"), 120)
    }

    func testRelativeMinutesMarkerAfter() {
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "Set up a focus event on my calendar 15 minutes from now"), 15)
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "add a break 20 min later"), 20)
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "meeting 1 hour from now"), 60)
    }

    func testRelativeMinutesWordForms() {
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "remind me in an hour"), 60)
        XCTAssertEqual(NativeToolSupport.relativeMinutes(in: "call mom in half an hour"), 30)
    }

    func testBareDurationIsNotRelative() {
        // "for 30 minutes" is a DURATION — must not be misread as an offset.
        XCTAssertNil(NativeToolSupport.relativeMinutes(in: "book the room at 6pm for 30 minutes"))
        XCTAssertNil(NativeToolSupport.relativeMinutes(in: "a 25 minutes focus session at 3pm"))
    }

    func testClockTimeRequestIsNotRelative() {
        XCTAssertNil(NativeToolSupport.relativeMinutes(in: "remind me to go to the gym at 6 pm"))
        XCTAssertNil(NativeToolSupport.relativeMinutes(in: "add a meeting tomorrow at 9:30am"))
    }
}
