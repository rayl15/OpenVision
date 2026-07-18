// OpenVision - TextChunkingTests.swift
// Sentence-boundary detection behind streamed TTS (speak completed sentences while generating).

import XCTest
@testable import OpenVision

final class TextChunkingTests: XCTestCase {

    private func boundaryOffset(_ s: String) -> Int? {
        guard let idx = TextChunking.lastSentenceBoundary(in: s) else { return nil }
        return s.distance(from: s.startIndex, to: idx)
    }

    func testSimpleSentence() {
        // Terminator at end-of-text counts; boundary is just past it.
        XCTAssertEqual(boundaryOffset("Hello there."), 12)
    }

    func testPicksLastCompletedSentence() {
        let s = "First. Second. Trailing fragment"
        XCTAssertEqual(boundaryOffset(s), 14)   // just past "Second." (dot + following space rule)
    }

    func testDecimalNumberIsNotABoundary() {
        // "2.5" must not split — the dot isn't followed by whitespace/end.
        XCTAssertNil(boundaryOffset("The value is 2"))
        XCTAssertEqual(boundaryOffset("The value is 2.5 today."), 23)
    }

    func testNewlineIsABoundary() {
        XCTAssertEqual(boundaryOffset("line one\nmore"), 9)
    }

    func testNoBoundaryInFragment() {
        XCTAssertNil(boundaryOffset("still streaming with no end yet"))
    }

    func testQuestionAndExclamation() {
        XCTAssertEqual(boundaryOffset("Really? Yes! And then"), 12)   // just past "Yes!"
    }
}
