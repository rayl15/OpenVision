// OpenVision - ContextualNoteTool.swift
// Voice notes auto-tagged with WHERE and WHEN you said them — the glasses-native productivity win.
// "Note: this cafe has great ramen" → saved with GPS + place name + timestamp; later searchable by
// content, tag, or location. Falls back gracefully to a plain note if location is unavailable.

import Foundation
import CoreLocation

struct ContextualNoteTool: NativeTool {
    let name = "note"
    let description = "Save, search, list, or delete quick notes. Notes are auto-tagged with your current location and time. Actions: 'save' (needs content), 'search' (needs query), 'list', 'delete' (needs query)."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "save, search, list, or delete"],
            "content": ["type": "string", "description": "The note text (for save)"],
            "tags": ["type": "string", "description": "Comma-separated tags (for save, optional)"],
            "query": ["type": "string", "description": "Keyword (for search/delete)"]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        switch (args["action"] as? String ?? "list").lowercased() {
        case "save", "note", "remember":
            guard let content = (args["content"] as? String)?.trimmingCharacters(in: .whitespaces), !content.isEmpty else {
                return "What should I note down?"
            }
            let tags = (args["tags"] as? String ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            let (loc, place) = await LocationHelper.shared.currentPlace()
            let note = ContextualNote(
                id: UUID().uuidString, content: content, tags: tags,
                latitude: loc?.coordinate.latitude, longitude: loc?.coordinate.longitude,
                locationName: place, createdAt: Date())
            ContextualNoteStore.shared.save(note)
            var response = "Noted"
            if let place { response += " at \(place)" }
            if !tags.isEmpty { response += " (tagged: \(tags.joined(separator: ", ")))" }
            return response + "."

        case "search", "find":
            let query = (args["query"] as? String ?? "").lowercased()
            guard !query.isEmpty else { return "What should I search your notes for?" }
            let results = ContextualNoteStore.shared.search(query)
            guard !results.isEmpty else { return "No notes match '\(query)'." }
            // Send the FULL text of the top matches so the model can actually reason over long notes
            // (not just a truncated preview). Bounded to 3 so context stays small.
            let top = results.prefix(3).map(Self.fullText).joined(separator: "\n---\n")
            let more = results.count > 3 ? "\n(plus \(results.count - 3) more match.)" : ""
            return "Found \(results.count) note\(results.count == 1 ? "" : "s"):\n\(top)\(more)"

        case "list", "recent":
            let notes = ContextualNoteStore.shared.recent(10)
            guard !notes.isEmpty else { return "No notes saved yet." }
            return "\(notes.count) recent: " + notes.prefix(5).map(Self.describe).joined(separator: "; ")

        case "delete":
            let query = (args["query"] as? String ?? args["content"] as? String ?? "").lowercased()
            guard !query.isEmpty else { return "Which note? Give me a keyword." }
            let n = ContextualNoteStore.shared.deleteMatching(query)
            return n > 0 ? "Deleted \(n) note\(n == 1 ? "" : "s")." : "No notes match '\(query)'."

        default:
            return "Use save, search, list, or delete."
        }
    }

    /// Short preview (for the recent list).
    private static func describe(_ note: ContextualNote) -> String {
        var d = String(note.content.prefix(50))
        if let loc = note.locationName { d += " (at \(loc))" }
        return d + " — \(note.timeAgo) ago"
    }

    /// Full note text + context (for search, so the model can reason over long notes).
    private static func fullText(_ note: ContextualNote) -> String {
        var d = note.content
        if let loc = note.locationName { d += " — at \(loc)" }
        return d + " (\(note.timeAgo) ago)"
    }
}

// MARK: - Model + store

struct ContextualNote: Codable, Identifiable {
    let id: String
    let content: String
    let tags: [String]
    let latitude: Double?
    let longitude: Double?
    let locationName: String?
    let createdAt: Date

    var timeAgo: String {
        let s = Int(Date().timeIntervalSince(createdAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 { return "\(s/3600)h" }
        return "\(s/86400)d"
    }
}

final class ContextualNoteStore {
    static let shared = ContextualNoteStore()
    private let key = "contextualNotes"

    func all() -> [ContextualNote] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let notes = try? JSONDecoder().decode([ContextualNote].self, from: data) else { return [] }
        return notes
    }
    func save(_ note: ContextualNote) { var n = all(); n.append(note); persist(n) }
    func recent(_ count: Int) -> [ContextualNote] { Array(all().sorted { $0.createdAt > $1.createdAt }.prefix(count)) }
    func search(_ q: String) -> [ContextualNote] {
        all().filter { $0.content.lowercased().contains(q) || $0.tags.contains { $0.contains(q) } || ($0.locationName?.lowercased().contains(q) ?? false) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    func deleteMatching(_ q: String) -> Int {
        var notes = all(); let before = notes.count
        notes.removeAll { $0.content.lowercased().contains(q) || $0.tags.contains(q) }
        persist(notes); return before - notes.count
    }
    private func persist(_ notes: [ContextualNote]) {
        if let data = try? JSONEncoder().encode(notes) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Location + reverse geocode (never blocks a note)

/// Uses the *cached* location rather than blocking on a fresh GPS fix — a note must save instantly.
/// The delegate keeps the last fix warm; the reverse-geocode is hard-bounded to ~3s. If no recent
/// location is available yet, the note simply saves without a place (and warms up for next time).
final class LocationHelper: NSObject, CLLocationManagerDelegate {
    static let shared = LocationHelper()
    private let manager = CLLocationManager()
    private var lastFix: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let s = manager.authorizationStatus
        if s == .authorizedWhenInUse || s == .authorizedAlways { manager.requestLocation() }
    }

    /// Touch the singleton at launch (from the main thread) so CLLocationManager lives on a thread
    /// with a run loop and its delegate callbacks fire.
    func prewarm() {}

    func currentPlace() async -> (CLLocation?, String?) {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()   // dialog now; this note saves without a place
            return (nil, nil)
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return (nil, nil) }
        let loc = lastFix ?? manager.location
        manager.requestLocation()   // refresh for next time (non-blocking)
        guard let loc, Date().timeIntervalSince(loc.timestamp) < 600 else { return (nil, nil) }
        let name = await Self.reverseGeocode(loc)
        return (loc, name)
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) { lastFix = locs.last }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    /// Completion-handler geocode with a hard 3s timeout (cancels the geocode) so it can never hang.
    private static func reverseGeocode(_ loc: CLLocation) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let geocoder = CLGeocoder()
            let once = GeocodeResume(c)
            geocoder.reverseGeocodeLocation(loc) { placemarks, _ in
                once.resume(placemarks?.first?.name ?? placemarks?.first?.subLocality ?? placemarks?.first?.locality)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                geocoder.cancelGeocode(); once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation exactly once (the geocode completion and the timeout race on the main queue).
private final class GeocodeResume {
    private var cont: CheckedContinuation<String?, Never>?
    init(_ c: CheckedContinuation<String?, Never>) { cont = c }
    func resume(_ s: String?) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: s)
    }
}
