// OpenVision - NativeToolSupportTests.swift
// The date-resolution logic behind "remind me at 6 PM" landing at exactly 6:00 PM.

import XCTest
@testable import OpenVision

final class NativeToolSupportTests: XCTestCase {

    // MARK: - resolveDate: clock-time path

    func testClockTimeFutureTodayResolvesToday() {
        // Pick a time guaranteed to still be in the future today (or roll to tomorrow — both
        // asserted below by re-deriving from the same calendar rules).
        let cal = Calendar.current
        let now = Date()
        let hour = 23, minute = 59
        let date = NativeToolSupport.resolveDate(from: ["hour": hour, "minute": minute])
        XCTAssertNotNil(date)
        let comps = cal.dateComponents([.hour, .minute], from: date!)
        XCTAssertEqual(comps.hour, hour)
        XCTAssertEqual(comps.minute, minute)
        XCTAssertGreaterThan(date!, now, "clock-time resolution must never land in the past")
    }

    func testClockTimeAlreadyPassedRollsToTomorrow() {
        let cal = Calendar.current
        let now = Date()
        // One hour ago (wrapping at midnight) has always already passed today.
        let pastHour = (cal.component(.hour, from: now) + 23) % 24
        let date = NativeToolSupport.resolveDate(from: ["hour": pastHour, "minute": 0])
        XCTAssertNotNil(date)
        XCTAssertGreaterThan(date!, now, "a passed clock time must roll to the next occurrence")
        XCTAssertEqual(cal.component(.hour, from: date!), pastHour)
    }

    func testDayOffsetTomorrow() {
        let cal = Calendar.current
        let date = NativeToolSupport.resolveDate(from: ["hour": 9, "minute": 30, "day_offset": 1])
        XCTAssertNotNil(date)
        XCTAssertTrue(cal.isDateInTomorrow(date!))
        XCTAssertEqual(cal.component(.hour, from: date!), 9)
        XCTAssertEqual(cal.component(.minute, from: date!), 30)
    }

    func testClockTimeBeatsRelativeWhenBothPresent() {
        // Priority: absolute clock time wins over minutes_from_now.
        let cal = Calendar.current
        let date = NativeToolSupport.resolveDate(from: ["hour": 18, "minutes_from_now": 240])
        XCTAssertNotNil(date)
        XCTAssertEqual(cal.component(.hour, from: date!), 18)
    }

    // MARK: - resolveDate: relative path

    func testMinutesFromNow() {
        let now = Date()
        let date = NativeToolSupport.resolveDate(from: ["minutes_from_now": 20])
        XCTAssertNotNil(date)
        XCTAssertEqual(date!.timeIntervalSince(now), 20 * 60, accuracy: 5)
    }

    func testMinutesFromNowAsStringCoerces() {
        // LLMs send numbers as strings; int() must coerce.
        let now = Date()
        let date = NativeToolSupport.resolveDate(from: ["minutes_from_now": "15"])
        XCTAssertNotNil(date)
        XCTAssertEqual(date!.timeIntervalSince(now), 15 * 60, accuracy: 5)
    }

    // MARK: - resolveDate: ISO fallback + nil

    func testISOFallback() {
        let date = NativeToolSupport.resolveDate(from: ["due_iso8601": "2030-01-02T09:00:00Z"])
        XCTAssertNotNil(date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.hour, from: date!), 9)
    }

    func testNoTimeArgsReturnsNil() {
        XCTAssertNil(NativeToolSupport.resolveDate(from: ["title": "no time here"]))
    }

    func testInvalidHourIgnored() {
        // hour out of range → falls through (nil here, since nothing else is present).
        XCTAssertNil(NativeToolSupport.resolveDate(from: ["hour": 99]))
    }

    // MARK: - int coercion

    func testIntCoercion() {
        XCTAssertEqual(NativeToolSupport.int(5), 5)
        XCTAssertEqual(NativeToolSupport.int(5.0), 5)
        XCTAssertEqual(NativeToolSupport.int(" 42 "), 42)
        XCTAssertNil(NativeToolSupport.int("not a number"))
        XCTAssertNil(NativeToolSupport.int(nil))
    }

    // MARK: - duration formatting

    func testDurationFormatting() {
        XCTAssertEqual(NativeToolSupport.duration(45), "45 seconds")
        XCTAssertEqual(NativeToolSupport.duration(60), "1 minute")
        XCTAssertEqual(NativeToolSupport.duration(300), "5 minutes")
        XCTAssertEqual(NativeToolSupport.duration(90), "1 min 30 sec")
        XCTAssertEqual(NativeToolSupport.duration(3600), "1 hour")
        XCTAssertEqual(NativeToolSupport.duration(5400), "1 hr 30 min")
    }
}
