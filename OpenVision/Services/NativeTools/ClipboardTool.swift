// OpenVision - ClipboardTool.swift
import Foundation
import UIKit

/// Copy text to the device clipboard so the user can paste it elsewhere.
struct ClipboardTool: NativeTool {
    let name = "copy_to_clipboard"
    let description = "Copy text to the clipboard. Use when the user says 'copy that' or wants a result saved to paste elsewhere."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string", "description": "The text to copy"]],
        "required": ["text"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String, !text.isEmpty else { return "There's nothing to copy." }
        await MainActor.run { UIPasteboard.general.string = text }
        let preview = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return "Copied to clipboard: \(preview)"
    }
}
