// OpenVision - MeetingNotesTests.swift
// Meeting notes: voice phrases, the stop-phrase cut, transcript chunking, summary parsing,
// the spoken recap, and the meetings tool's answers.

import XCTest
@testable import OpenVision

final class MeetingNotesTests: XCTestCase {

    // MARK: - Start phrases

    func testStartPhrases() {
        XCTAssertTrue(MeetingNotesLogic.isStartCommand("Start taking notes"))
        XCTAssertTrue(MeetingNotesLogic.isStartCommand("ok vision, take meeting notes please"))
        XCTAssertTrue(MeetingNotesLogic.isStartCommand("Record this meeting."))
    }

    func testQuickNoteIsNotAMeeting() {
        // "Take a note" saves a quick note with the note tool; it must not start recording.
        XCTAssertFalse(MeetingNotesLogic.isStartCommand("take a note: buy milk"))
        XCTAssertFalse(MeetingNotesLogic.isStartCommand("note that I parked in lot B"))
        XCTAssertFalse(MeetingNotesLogic.isStartCommand("add a meeting tomorrow at 9"))
        XCTAssertFalse(MeetingNotesLogic.isStartCommand("remind me to start a meeting at 3"))
    }

    // MARK: - Stop phrase

    func testNoStopPhrase() {
        XCTAssertNil(MeetingNotesLogic.textBeforeStopCommand("we should stop the project next week"))
    }

    func testStopPhraseCutsTranscript() {
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("Let's ship on Friday. Stop taking notes."),
                       "Let's ship on Friday")
    }

    func testStopPhraseDropsWakeWord() {
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("Thanks everyone, OK Vision, stop taking notes"),
                       "Thanks everyone")
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("okay vision stop meeting notes"), "")
    }

    func testStopPhraseToleratesPunctuation() {
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("That's all. Stop, taking notes."), "That's all")
    }

    func testEarliestStopPhraseWins() {
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("done stop the notes then stop taking notes"), "done")
    }

    // MARK: - Hindi and Hinglish

    func testHinglishStartPhrase() {
        XCTAssertTrue(MeetingNotesLogic.isStartCommand("ok vision notes lena shuru karo"))
    }

    func testHindiStopPhrase() {
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("हम शुक्रवार को लॉन्च करेंगे। नोट्स बंद करो।"),
                       "हम शुक्रवार को लॉन्च करेंगे")
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("बजट तय हो गया, ओके विज़न, नोट्स लेना बंद करो"),
                       "बजट तय हो गया")
        XCTAssertNil(MeetingNotesLogic.textBeforeStopCommand("हमने नोट्स शेयर किए"))
    }

    func testHinglishStopPhrase() {
        XCTAssertEqual(MeetingNotesLogic.textBeforeStopCommand("theek hai, deck Friday tak bhejo. Notes band karo"),
                       "theek hai, deck Friday tak bhejo")
    }

    func testStopHint() {
        XCTAssertTrue(MeetingNotesLogic.stopHint(localeID: "hi_IN").contains("नोट्स बंद करो"))
        XCTAssertTrue(MeetingNotesLogic.stopHint(localeID: "mul_IN").contains("notes band karo"))
        XCTAssertEqual(MeetingNotesLogic.stopHint(localeID: "en_US"), "\"stop taking notes\"")
    }

    func testScriptDetection() {
        XCTAssertTrue(MeetingNotesLogic.isMostlyLatin("Let's ship on Friday"))
        XCTAssertTrue(MeetingNotesLogic.isMostlyLatin("deck Friday tak bhejo"))
        XCTAssertFalse(MeetingNotesLogic.isMostlyLatin("हम शुक्रवार को लॉन्च करेंगे"))
    }

    func testChunkSizeFollowsContextAndScript() {
        XCTAssertEqual(MeetingNotesLogic.chunkChars(contextTokens: nil, sample: "anything"), 60_000)
        XCTAssertEqual(MeetingNotesLogic.chunkChars(contextTokens: 8_192, sample: "English text"), 6_192 * 3)
        XCTAssertEqual(MeetingNotesLogic.chunkChars(contextTokens: 8_192, sample: "हिन्दी पाठ"), 6_192)
        XCTAssertEqual(MeetingNotesLogic.chunkChars(contextTokens: 2_048, sample: "tiny"), 3_000, "never below 1,000 tokens")
    }

    func testSummaryLanguageInstruction() {
        XCTAssertTrue(MeetingNotesLogic.summarySystem(localeID: "hi_IN", writeInEnglish: false).contains("language the meeting was held in"))
        XCTAssertTrue(MeetingNotesLogic.summarySystem(localeID: "hi_IN", writeInEnglish: true).contains("in English"))
        XCTAssertTrue(MeetingNotesLogic.summarySystem(localeID: "mul_IN", writeInEnglish: false).contains("in English"))
    }

    func testRecapSkipsNonLatinOverview() {
        let s = MeetingSummary(title: "", overview: "बजट पर चर्चा हुई।", decisions: ["x"], actionItems: [])
        let recap = MeetingNotesLogic.spokenRecap(s)
        XCTAssertFalse(recap.contains("बजट"))
        XCTAssertTrue(recap.hasPrefix("1 decision"))
    }

    func testHindiSearchMatching() {
        var m = Meeting(startedAt: Date())
        m.status = .needsSummary
        m.segments = [.init(offset: 0, text: "मार्केटिंग का बजट तय हुआ")]
        let answer = MeetingsTool.answer(action: "search", query: "बजट", meetings: [m])
        XCTAssertTrue(answer.contains("मार्केटिंग का बजट तय हुआ"))
    }

    // MARK: - Chunking

    func testShortTranscriptIsOneChunk() {
        XCTAssertEqual(MeetingNotesLogic.chunks("hello\nworld", maxChars: 100), ["hello\nworld"])
        XCTAssertEqual(MeetingNotesLogic.chunks("   ", maxChars: 100), [])
    }

    func testChunksBreakBetweenLinesAndStayUnderBudget() {
        let lines = (1...50).map { "Line number \($0) of the meeting." }
        let chunks = MeetingNotesLogic.chunks(lines.joined(separator: "\n"), maxChars: 200)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 200 })
        // Nothing lost or reordered.
        XCTAssertEqual(chunks.joined(separator: "\n"), lines.joined(separator: "\n"))
    }

    func testOverlongLineSplitsBySentence() {
        let line = (1...20).map { "Sentence \($0) is here." }.joined(separator: " ")
        let chunks = MeetingNotesLogic.chunks(line, maxChars: 80)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 80 })
        XCTAssertTrue(chunks.first!.hasPrefix("Sentence 1 is here."))
    }

    func testOverlongWordIsHardSplit() {
        let word = String(repeating: "a", count: 250)
        let chunks = MeetingNotesLogic.chunks(word, maxChars: 100)
        XCTAssertEqual(chunks.map(\.count), [100, 100, 50])
    }

    // MARK: - Summary parsing

    func testParsesJSONSummary() {
        let reply = """
        {"title":"Launch plan","overview":"We agreed the launch date.","decisions":["Ship Friday"],
         "action_items":[{"task":"Send the deck","owner":"Priya","due":"Thursday"},{"task":"Book room","owner":"","due":"none"}]}
        """
        let s = MeetingNotesLogic.parseSummary(reply)
        XCTAssertEqual(s.title, "Launch plan")
        XCTAssertEqual(s.overview, "We agreed the launch date.")
        XCTAssertEqual(s.decisions, ["Ship Friday"])
        XCTAssertEqual(s.actionItems.count, 2)
        XCTAssertEqual(s.actionItems[0].owner, "Priya")
        XCTAssertEqual(s.actionItems[0].due, "Thursday")
        XCTAssertNil(s.actionItems[1].owner, "empty owner is dropped")
        XCTAssertNil(s.actionItems[1].due, "placeholder 'none' is dropped")
    }

    func testEchoedPlaceholdersAreDropped() {
        // Seen on device: Apple Intelligence copied "who" from the field description.
        let s = MeetingNotesLogic.parseSummary(#"{"title":"T","overview":"O","decisions":[],"action_items":[{"task":"Compare engines","owner":"who","due":"when, or empty"}]}"#)
        XCTAssertNil(s.actionItems.first?.owner)
        XCTAssertNil(s.actionItems.first?.due)
        XCTAssertEqual(s.actionItems.first?.task, "Compare engines")
    }

    func testParsesFencedJSONWithProseAround() {
        let reply = "Here are the notes:\n```json\n{\"title\":\"Sync\",\"overview\":\"Short sync.\",\"decisions\":[],\"action_items\":[\"Email Sam\"]}\n```"
        let s = MeetingNotesLogic.parseSummary(reply)
        XCTAssertEqual(s.title, "Sync")
        XCTAssertEqual(s.actionItems.map(\.task), ["Email Sam"])
    }

    func testProseReplyBecomesOverview() {
        let s = MeetingNotesLogic.parseSummary("The team discussed hiring and agreed to post the role.")
        XCTAssertEqual(s.overview, "The team discussed hiring and agreed to post the role.")
        XCTAssertTrue(s.decisions.isEmpty)
        XCTAssertTrue(s.actionItems.isEmpty)
    }

    // MARK: - Recap and formatting

    func testSpokenRecap() {
        let s = MeetingSummary(title: "T", overview: "We picked a date. Then we argued about lunch.",
                               decisions: ["Ship Friday"],
                               actionItems: [ActionItem(task: "Send the deck", owner: "Priya", due: "Thursday"),
                                             ActionItem(task: "Book room")])
        let recap = MeetingNotesLogic.spokenRecap(s)
        XCTAssertTrue(recap.hasPrefix("We picked a date."))
        XCTAssertFalse(recap.contains("lunch"), "only the first sentence of the overview is spoken")
        XCTAssertTrue(recap.contains("1 decision and 2 action items."))
        XCTAssertTrue(recap.contains("First action item: Send the deck (Priya, Thursday)."))
    }

    func testRecapWithNothingToReport() {
        let recap = MeetingNotesLogic.spokenRecap(MeetingSummary(title: "", overview: "", decisions: [], actionItems: []))
        XCTAssertTrue(recap.hasPrefix("No decisions and no action items."))
    }

    func testClock() {
        XCTAssertEqual(MeetingNotesLogic.clock(0), "0:00")
        XCTAssertEqual(MeetingNotesLogic.clock(65), "1:05")
        XCTAssertEqual(MeetingNotesLogic.clock(3723), "1:02:03")
    }

    // MARK: - Model

    func testActionItemDecodesWithoutIDOrFlag() throws {
        let item = try JSONDecoder().decode(ActionItem.self, from: Data(#"{"task":"Call Sam"}"#.utf8))
        XCTAssertEqual(item.task, "Call Sam")
        XCTAssertFalse(item.addedToReminders)
    }

    func testMeetingTranscriptAndTitle() {
        var m = Meeting(startedAt: Date(timeIntervalSince1970: 0))
        m.segments = [.init(offset: 0, text: "Hello there"), .init(offset: 75, text: "Next topic")]
        XCTAssertEqual(m.transcript, "Hello there\nNext topic")
        XCTAssertEqual(m.timestampedTranscript, "[0:00] Hello there\n[1:15] Next topic")
        XCTAssertEqual(m.wordCount, 4)
        XCTAssertTrue(m.title.hasPrefix("Meeting, "), "untitled meetings get a dated title")
        m.summary = MeetingSummary(title: "Budget review", overview: "", decisions: [], actionItems: [])
        XCTAssertEqual(m.title, "Budget review")
    }

    // MARK: - Meetings tool

    private func sampleMeetings() -> [Meeting] {
        var a = Meeting(startedAt: Date().addingTimeInterval(-3600))
        a.endedAt = a.startedAt.addingTimeInterval(1800)
        a.status = .ready
        a.segments = [.init(offset: 0, text: "We reviewed the budget for marketing")]
        a.summary = MeetingSummary(title: "Budget review", overview: "Marketing budget agreed.",
                                   decisions: ["Cap spend at 10k"],
                                   actionItems: [ActionItem(task: "Update the sheet", owner: "Ana")])
        var b = Meeting(startedAt: Date().addingTimeInterval(-86400))
        b.endedAt = b.startedAt.addingTimeInterval(600)
        b.status = .needsSummary
        b.segments = [.init(offset: 0, text: "Hiring plan for the design team")]
        var recording = Meeting(startedAt: Date())
        recording.status = .recording
        return [recording, a, b]
    }

    func testToolLatestSkipsMeetingInProgress() {
        let answer = MeetingsTool.answer(action: "latest", query: "", meetings: sampleMeetings())
        XCTAssertTrue(answer.contains("Budget review"))
        XCTAssertTrue(answer.contains("Cap spend at 10k"))
        XCTAssertTrue(answer.contains("Update the sheet (Ana)"))
    }

    func testToolSearchFindsTranscriptOfUnsummarisedMeeting() {
        let answer = MeetingsTool.answer(action: "search", query: "design hiring", meetings: sampleMeetings())
        XCTAssertTrue(answer.contains("Hiring plan for the design team"))
        XCTAssertFalse(answer.contains("Budget review"))
    }

    func testToolSearchMiss() {
        XCTAssertEqual(MeetingsTool.answer(action: "search", query: "kubernetes", meetings: sampleMeetings()),
                       "No meetings mention 'kubernetes'.")
    }

    func testToolActionItems() {
        let answer = MeetingsTool.answer(action: "action_items", query: "", meetings: sampleMeetings())
        XCTAssertEqual(answer, "Open action items: Update the sheet (Ana) — from Budget review.")
    }

    func testGroupByDay() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 15))!
        func meeting(daysAgo: Int, hour: Int) -> Meeting {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
            return Meeting(startedAt: cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!)
        }
        let list = [meeting(daysAgo: 0, hour: 14), meeting(daysAgo: 0, hour: 9),
                    meeting(daysAgo: 1, hour: 10), meeting(daysAgo: 3, hour: 10), meeting(daysAgo: 400, hour: 10)]
        let groups = MeetingsView.groupByDay(list, calendar: cal, now: now)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups[0].title, "Today")
        XCTAssertEqual(groups[0].meetings.count, 2)
        XCTAssertEqual(groups[1].title, "Yesterday")
        XCTAssertFalse(groups[2].title.contains("2026") || groups[2].title.contains("2025"), "this year's days omit the year")
        XCTAssertTrue(groups[3].title.contains("2025"), "older years show the year")
    }

    func testToolWithNoMeetings() {
        XCTAssertTrue(MeetingsTool.answer(action: "latest", query: "", meetings: []).hasPrefix("No meetings recorded yet"))
    }
}
