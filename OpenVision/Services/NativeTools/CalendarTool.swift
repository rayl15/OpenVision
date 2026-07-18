// OpenVision - CalendarTool.swift
import Foundation
import EventKit

/// Read the calendar (today / upcoming) or add an event.
struct CalendarTool: NativeTool {
    let name = "calendar"
    let description = "Read or add calendar events. action 'today' lists today's events, 'upcoming' lists the next 7 days, 'add' creates an event (needs title and start_iso8601)."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "today, upcoming, or add"],
            "title": ["type": "string", "description": "Event title (for add)"],
            "hour": ["type": "integer", "description": "For add at a clock time like '3pm': the hour in 24-hour form (0-23). USE THIS for any specific time of day — do not compute minutes yourself."],
            "minute": ["type": "integer", "description": "Minute 0-59 (with hour). Default 0."],
            "day_offset": ["type": "integer", "description": "With hour: 0=today, 1=tomorrow, 2=in two days. Default 0."],
            "minutes_from_now": ["type": "integer", "description": "For add: start this many minutes from now. USE ONLY for 'in N minutes / from now', never for a clock time."],
            "start_iso8601": ["type": "string", "description": "For add: an absolute start time in ISO 8601. Last resort only."],
            "duration_minutes": ["type": "integer", "description": "Length in minutes (for add, default 30)"]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "today").lowercased()
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .event)) ?? false
        }
        guard granted else { return "I need Calendar access — enable it in Settings, then ask again." }

        if action == "add" {
            guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
                return "What should I call the event?"
            }
            // The tool resolves the time (clock time / relative / ISO) so the model never does date math.
            guard let start = NativeToolSupport.resolveDate(from: args) else {
                return "When should the event start?"
            }
            NSLog("[Calendar] add event at %@", "\(start)")
            guard let calendar = store.defaultCalendarForNewEvents else {
                return "I couldn't find a default calendar to add to. Check that a writable calendar is set in the Calendar app."
            }
            let minutes = NativeToolSupport.int(args["duration_minutes"]) ?? 30
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
            event.calendar = calendar
            try store.save(event, span: .thisEvent)
            NSLog("[Calendar] saved event at %@ to calendar '%@'", "\(start)", calendar.title)
            return "Added \"\(title)\" \(NativeToolSupport.friendly(start)) to \(calendar.title)."
        }

        // Read: today or upcoming.
        let now = Date()
        let cal = Calendar.current
        let end: Date = action == "upcoming"
            ? (cal.date(byAdding: .day, value: 7, to: now) ?? now)
            : (cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else {
            return action == "upcoming" ? "Nothing on your calendar this week." : "Nothing left on your calendar today."
        }
        let list = events.prefix(5).map { "\($0.title ?? "event") \(NativeToolSupport.friendly($0.startDate))" }
            .joined(separator: "; ")
        return "\(events.count) event\(events.count == 1 ? "" : "s"): \(list)."
    }
}
