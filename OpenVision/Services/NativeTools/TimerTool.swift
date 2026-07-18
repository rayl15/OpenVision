// OpenVision - TimerTool.swift
import Foundation
import UserNotifications

/// Set a countdown timer via a local notification. No external API.
struct TimerTool: NativeTool {
    let name = "set_timer"
    let description = "Set a countdown timer that notifies the user after a duration. Use for 'set a 10 minute timer', 'timer for the pasta', etc."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "seconds": ["type": "integer", "description": "Duration in seconds"],
            "label": ["type": "string", "description": "Optional label, e.g. 'pasta' or 'break'"]
        ],
        "required": ["seconds"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let seconds = NativeToolSupport.int(args["seconds"]) ?? 0
        guard seconds > 0, seconds <= 86400 else { return "A timer needs a duration between 1 second and 24 hours." }
        let label = args["label"] as? String
        guard await NativeToolSupport.ensureNotificationAuth() else {
            return "Timer noted, but notifications are off, so I can't alert you. Enable them in Settings."
        }
        let content = UNMutableNotificationContent()
        content.title = label.map { "\($0.capitalized) timer" } ?? "Timer"
        content.body = label != nil ? "Time's up — your \(label!) timer is done! ⏰" : "Time's up! Your \(NativeToolSupport.duration(seconds)) timer is done. ⏰"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "timer-\(UUID().uuidString)", content: content, trigger: trigger))
        let d = NativeToolSupport.duration(seconds)
        return label.map { "Timer set: \($0) for \(d)." } ?? "Timer set for \(d)."
    }
}
