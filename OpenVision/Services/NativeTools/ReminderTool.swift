// OpenVision - ReminderTool.swift
import Foundation
import EventKit

/// Create a reminder in Apple Reminders, optionally with a due date/time.
struct ReminderTool: NativeTool {
    let name = "create_reminder"
    let description = "Create a reminder in Apple Reminders, optionally with a due time. Use for 'remind me to call mom at 5pm', 'remind me to buy milk'."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "What to be reminded about"],
            "hour": ["type": "integer", "description": "For a clock time like '6pm' or '9:30am': the hour in 24-hour form (0-23). USE THIS for any specific time of day — do not compute minutes yourself."],
            "minute": ["type": "integer", "description": "Minute 0-59 (with hour). Default 0."],
            "day_offset": ["type": "integer", "description": "With hour: 0=today, 1=tomorrow, 2=in two days. Default 0."],
            "minutes_from_now": ["type": "integer", "description": "Due this many minutes from now. USE ONLY for 'in N minutes / from now', never for a clock time."],
            "due_iso8601": ["type": "string", "description": "Absolute due date/time in ISO 8601. Last resort only."]
        ],
        "required": ["title"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            return "What should I remind you about?"
        }
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }
        guard granted else { return "I need Reminders access — enable it in Settings, then ask again." }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()

        var whenStr = ""
        let dueDate = NativeToolSupport.resolveDate(from: args)
        if let date = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
            whenStr = " for \(NativeToolSupport.friendly(date))"
        }
        try store.save(reminder, commit: true)
        return "Reminder added: \(title)\(whenStr)."
    }
}
