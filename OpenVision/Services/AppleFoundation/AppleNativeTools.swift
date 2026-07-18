// OpenVision - AppleNativeTools.swift
// Bridges the productivity NativeTools into Apple's Foundation Models tool-calling.
//
// Apple's `Tool` protocol wants a typed `@Generable` Arguments struct (not our [String: Any] schema),
// so we write one thin wrapper per tool — but each just forwards to the shared NativeToolRegistry, so
// all the real work (EventKit, notifications, location, clipboard) lives in one place.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
enum AppleNativeTools {
    /// All native tools, ready to hand to a LanguageModelSession.
    static var all: [any Tool] {
        [AppleTimerTool(), ApplePomodoroTool(), AppleReminderTool(),
         AppleCalendarTool(), AppleNoteTool(), AppleClipboardTool()]
    }

    /// Run a native tool by name with a cleaned-up arg dict (drops empty strings / zeros meaning "unset").
    static func run(_ name: String, _ args: [String: Any]) async -> String {
        await NativeToolRegistry.shared.execute(name: name, args: args)
    }
}

@available(iOS 26.0, *)
struct AppleTimerTool: Tool {
    let name = "set_timer"
    let description = "Set a countdown timer that alerts after a duration. For 'set a 10 minute timer', 'timer for the pasta'."
    @Generable struct Arguments {
        @Guide(description: "Duration in seconds") let seconds: Int
        @Guide(description: "Optional label, e.g. 'pasta'. Empty if none.") let label: String
    }
    func call(arguments: Arguments) async throws -> String {
        var args: [String: Any] = ["seconds": arguments.seconds]
        if !arguments.label.isEmpty { args["label"] = arguments.label }
        return await AppleNativeTools.run(name, args)
    }
}

@available(iOS 26.0, *)
struct ApplePomodoroTool: Tool {
    let name = "start_pomodoro"
    let description = "Start a Pomodoro focus session (a work block then a break). Defaults: 25 min work, 5 min break — pass 0 to use a default."
    @Generable struct Arguments {
        @Guide(description: "Focus minutes, or 0 for default (25)") let work_minutes: Int
        @Guide(description: "Break minutes, or 0 for default (5)") let break_minutes: Int
    }
    func call(arguments: Arguments) async throws -> String {
        var args: [String: Any] = [:]
        if arguments.work_minutes > 0 { args["work_minutes"] = arguments.work_minutes }
        if arguments.break_minutes > 0 { args["break_minutes"] = arguments.break_minutes }
        return await AppleNativeTools.run(name, args)
    }
}

@available(iOS 26.0, *)
struct AppleReminderTool: Tool {
    let name = "create_reminder"
    let description = "Create a reminder in Apple Reminders, optionally with a due time."
    @Generable struct Arguments {
        @Guide(description: "What to be reminded about") let title: String
        @Guide(description: "For a clock time like '6pm': the hour in 24-hour form (0-23), or -1 if none. USE THIS for any time of day.") let hour: Int
        @Guide(description: "Minute 0-59 (with hour). 0 if none.") let minute: Int
        @Guide(description: "With hour: 0=today, 1=tomorrow, 2=in two days.") let day_offset: Int
        @Guide(description: "Due this many minutes from now, or 0. ONLY for 'in N minutes', never a clock time.") let minutes_from_now: Int
    }
    func call(arguments: Arguments) async throws -> String {
        var args: [String: Any] = ["title": arguments.title]
        if (0...23).contains(arguments.hour) {
            args["hour"] = arguments.hour
            args["minute"] = arguments.minute
            args["day_offset"] = arguments.day_offset
        } else if arguments.minutes_from_now > 0 {
            args["minutes_from_now"] = arguments.minutes_from_now
        }
        return await AppleNativeTools.run(name, args)
    }
}

@available(iOS 26.0, *)
struct AppleCalendarTool: Tool {
    let name = "calendar"
    let description = "Read or add calendar events. action 'today', 'upcoming', or 'add' (add needs title and start_iso8601)."
    @Generable struct Arguments {
        @Guide(description: "today, upcoming, or add") let action: String
        @Guide(description: "Event title (for add). Empty otherwise.") let title: String
        @Guide(description: "For add at a clock time like '3pm': the hour in 24-hour form (0-23), or -1 if none. USE THIS for any time of day.") let hour: Int
        @Guide(description: "Minute 0-59 (with hour). 0 if none.") let minute: Int
        @Guide(description: "With hour: 0=today, 1=tomorrow, 2=in two days.") let day_offset: Int
        @Guide(description: "For add: minutes from now, or 0. ONLY for 'in N minutes', never a clock time.") let minutes_from_now: Int
        @Guide(description: "Length in minutes (for add), or 0 for default") let duration_minutes: Int
    }
    func call(arguments: Arguments) async throws -> String {
        var args: [String: Any] = ["action": arguments.action]
        if !arguments.title.isEmpty { args["title"] = arguments.title }
        if (0...23).contains(arguments.hour) {
            args["hour"] = arguments.hour
            args["minute"] = arguments.minute
            args["day_offset"] = arguments.day_offset
        } else if arguments.minutes_from_now > 0 {
            args["minutes_from_now"] = arguments.minutes_from_now
        }
        if arguments.duration_minutes > 0 { args["duration_minutes"] = arguments.duration_minutes }
        return await AppleNativeTools.run(name, args)
    }
}

@available(iOS 26.0, *)
struct AppleNoteTool: Tool {
    let name = "note"
    let description = "Save, search, list, or delete quick notes (auto-tagged with location + time). save needs content; search/delete need query."
    @Generable struct Arguments {
        @Guide(description: "save, search, list, or delete") let action: String
        @Guide(description: "Note text (for save). Empty otherwise.") let content: String
        @Guide(description: "Comma-separated tags (for save, optional)") let tags: String
        @Guide(description: "Keyword (for search/delete). Empty otherwise.") let query: String
    }
    func call(arguments: Arguments) async throws -> String {
        var args: [String: Any] = ["action": arguments.action]
        if !arguments.content.isEmpty { args["content"] = arguments.content }
        if !arguments.tags.isEmpty { args["tags"] = arguments.tags }
        if !arguments.query.isEmpty { args["query"] = arguments.query }
        return await AppleNativeTools.run(name, args)
    }
}

@available(iOS 26.0, *)
struct AppleClipboardTool: Tool {
    let name = "copy_to_clipboard"
    let description = "Copy text to the clipboard. For 'copy that'."
    @Generable struct Arguments {
        @Guide(description: "The text to copy") let text: String
    }
    func call(arguments: Arguments) async throws -> String {
        await AppleNativeTools.run(name, ["text": arguments.text])
    }
}
#endif
