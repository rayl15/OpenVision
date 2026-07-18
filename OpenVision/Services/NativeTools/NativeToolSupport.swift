// OpenVision - NativeToolSupport.swift
// Small shared helpers for the native tools (arg coercion, notification auth, date formatting).

import Foundation
import UserNotifications

/// The user utterance that triggered the current model turn. Backends set it before invoking
/// their model so the registry can sanity-check tool args against what the user actually said
/// (see `NativeToolSupport.applyRelativeTimeGuard`). Entries expire — a tool call fired long
/// after the last text command (e.g. a Gemini audio turn) must not match a stale utterance.
@MainActor
final class NativeToolContext {
    static let shared = NativeToolContext()
    private init() {}

    private var command: String?
    private var setAt = Date.distantPast

    func set(_ command: String) {
        self.command = command
        self.setAt = Date()
    }

    /// The utterance, if one was recorded within the last two minutes.
    func recentCommand() -> String? {
        guard Date().timeIntervalSince(setAt) < 120 else { return nil }
        return command
    }
}

enum NativeToolSupport {

    /// Minutes parsed from a clearly RELATIVE time phrase in the user's words, or nil.
    /// Matches "in 15 minutes", "after 2 hours", "15 minutes from now", "20 min later",
    /// "in an hour", "in half an hour". A bare "30 minutes" does NOT match — without a relative
    /// marker it's likelier a duration ("book the room for 30 minutes").
    static func relativeMinutes(in command: String) -> Int? {
        let s = command.lowercased()
        if s.range(of: #"\b(in|after) half an hour\b"#, options: .regularExpression) != nil { return 30 }
        if s.range(of: #"\b(in|after) an hour\b"#, options: .regularExpression) != nil { return 60 }
        // Marker before ("in/after N unit") or after ("N unit from now/later").
        let pattern = #"\b(?:in|after)\s+(\d+)\s*(minute|min|hour|hr)s?\b|\b(\d+)\s*(minute|min|hour|hr)s?\s+(?:from now|later)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        for (numIdx, unitIdx) in [(1, 2), (3, 4)] {
            guard let numRange = Range(m.range(at: numIdx), in: s),
                  let unitRange = Range(m.range(at: unitIdx), in: s),
                  let n = Int(s[numRange]) else { continue }
            let isHours = s[unitRange].hasPrefix("h")
            return isHours ? n * 60 : n
        }
        return nil
    }

    /// Deterministic time guard: when the user's own words are RELATIVE ("in 15 minutes",
    /// "15 minutes from now"), rewrite the tool's time args to `minutes_from_now` parsed straight
    /// from the utterance — overriding whatever absolute time the model computed. Models (small
    /// ones especially) routinely do "now + 15" wrong; the transcript is ground truth. Returns
    /// the parsed minutes when the override applied, for logging.
    static func applyRelativeTimeGuard(_ args: inout [String: Any], command: String?) -> Int? {
        guard let command, let rel = relativeMinutes(in: command) else { return nil }
        for key in ["hour", "minute", "day_offset", "due_iso8601", "start_iso8601"] {
            args.removeValue(forKey: key)
        }
        args["minutes_from_now"] = rel
        return rel
    }

    /// LLMs send numbers as Int, Double, or even String — coerce to Int.
    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Ensure we can post local notifications (timers/alarms/pomodoro). Requests once if undetermined.
    static func ensureNotificationAuth() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    /// Human duration, e.g. "10 minutes", "1 hr 30 min".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) second\(seconds == 1 ? "" : "s")" }
        let m = seconds / 60, s = seconds % 60
        if m < 60 { return s == 0 ? "\(m) minute\(m == 1 ? "" : "s")" : "\(m) min \(s) sec" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h) hr \(rm) min"
    }

    /// Parse an ISO-8601 timestamp the model provides for a due/start time.
    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Fall back to a lenient local parse ("2026-07-18 17:00").
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = df.date(from: s) { return d }
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.date(from: s)
    }

    /// Resolve a target Date from tool args, preferring the most reliable source so a small model
    /// never has to do clock arithmetic. Priority:
    ///   1. Absolute clock time — `hour` (0-23) + optional `minute` + optional `day_offset`
    ///      (0=today, 1=tomorrow, …). The TOOL does the date math, not the model. If no day is given
    ///      and the time already passed today, it rolls to the next occurrence (tomorrow).
    ///   2. `minutes_from_now` — a relative offset in minutes.
    ///   3. `due_iso8601` / `start_iso8601` — an absolute ISO timestamp (last-resort fallback).
    /// Returns nil if none is present.
    static func resolveDate(from args: [String: Any]) -> Date? {
        let cal = Calendar.current
        let now = Date()

        // 1) Absolute clock time — most reliable, since the model only maps "6 PM" → hour 18.
        if let hour = int(args["hour"]), (0...23).contains(hour) {
            let minute = min(max(int(args["minute"]) ?? 0, 0), 59)
            let dayOffset = int(args["day_offset"]) ?? 0
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour; comps.minute = minute; comps.second = 0
            guard var date = cal.date(from: comps) else { return nil }
            if dayOffset != 0 {
                date = cal.date(byAdding: .day, value: dayOffset, to: date) ?? date
            } else if date <= now {
                // "at 6 PM" when it's already past 6 PM → next occurrence.
                date = cal.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }

        // 2) Relative minutes.
        if let rel = int(args["minutes_from_now"]), rel > 0 {
            return now.addingTimeInterval(TimeInterval(rel * 60))
        }

        // 3) ISO fallback.
        if let iso = (args["due_iso8601"] as? String) ?? (args["start_iso8601"] as? String),
           !iso.isEmpty {
            return parseISO(iso)
        }
        return nil
    }

    /// Friendly spoken date/time, e.g. "today at 5:00 PM", "Fri at 9:00 AM".
    static func friendly(_ date: Date) -> String {
        let cal = Calendar.current
        let time = DateFormatter(); time.dateFormat = "h:mm a"
        let t = time.string(from: date)
        if cal.isDateInToday(date) { return "today at \(t)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(t)" }
        let day = DateFormatter(); day.dateFormat = "EEE MMM d"
        return "\(day.string(from: date)) at \(t)"
    }
}
