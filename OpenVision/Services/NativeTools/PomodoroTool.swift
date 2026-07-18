// OpenVision - PomodoroTool.swift
import Foundation
import UserNotifications

/// Start a Pomodoro: a focus block followed by a break, each ending with a notification.
struct PomodoroTool: NativeTool {
    let name = "start_pomodoro"
    let description = "Start a Pomodoro focus session: a work block then a break, each ending with an alert. Defaults: 25 min work, 5 min break."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "work_minutes": ["type": "integer", "description": "Focus block length in minutes (default 25)"],
            "break_minutes": ["type": "integer", "description": "Break length in minutes (default 5)"]
        ]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let work = max(1, min(120, NativeToolSupport.int(args["work_minutes"]) ?? 25))
        let brk = max(1, min(60, NativeToolSupport.int(args["break_minutes"]) ?? 5))
        guard await NativeToolSupport.ensureNotificationAuth() else {
            return "I couldn't start the Pomodoro because notifications are off. Enable them in Settings."
        }
        let center = UNUserNotificationCenter.current()
        try await center.add(Self.request(after: work * 60, title: "Focus done", body: "Take a \(brk)-minute break."))
        try await center.add(Self.request(after: (work + brk) * 60, title: "Break over", body: "Back to focus."))
        return "Pomodoro started: \(work) minutes focus, then a \(brk)-minute break."
    }

    private static func request(after seconds: Int, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        return UNNotificationRequest(identifier: "pomodoro-\(UUID().uuidString)", content: content, trigger: trigger)
    }
}
