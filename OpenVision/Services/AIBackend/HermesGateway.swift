// OpenVision - HermesGateway.swift
// Username-and-password mode for the Hermes backend: sign in to the Hermes web UI (dashboard)
// and chat over its gateway WebSocket, the way the Hermes Desktop app does.
//
// Sign-in is Hermes' documented native-app flow (RFC 8252): /auth/native/authorize with PKCE and
// a 127.0.0.1 loopback redirect lands the login sheet on the dashboard's own username/password
// form, and /auth/native/token returns access + refresh tokens (Keychain, via OAuthTokenStore).
//
// Chat is JSON-RPC 2.0 over /api/ws, authorized with a 30s single-use ticket from
// /api/auth/ws-ticket. This is Hermes' internal "tui_gateway" protocol (desktop contract 8 at the
// time of writing), not a documented public API, so it can change between Hermes releases; the
// API-key mode (HermesService, OpenAI-compatible API server) is the stable alternative.
// One turn: session.create/resume → image.attach_bytes → prompt.submit → events until
// message.complete. Mid-turn the server can ask the client things (approval, clarify, …):
// approvals and questions are put to the user by voice through `askUser`; secrets, sudo and the
// vault are always declined — nobody should speak a password into their glasses.

import Foundation

/// Sign-in configuration for a Hermes dashboard at `base` (scheme, host and any proxy prefix).
enum HermesDashboard {
    /// Any port works for Hermes' native flow; the host must be the literal 127.0.0.1.
    nonisolated static let callbackPort: UInt16 = 47863

    nonisolated static func provider(base: URL) -> OAuthProvider {
        OAuthProvider(
            id: accountId(base: base),
            displayName: "Hermes",
            authorizeURL: base.appendingPathComponent("auth/native/authorize"),
            tokenURL: base.appendingPathComponent("auth/native/token"),
            clientId: "",
            scope: "",
            redirectHost: "127.0.0.1",
            redirectPort: callbackPort,
            redirectPath: "/callback",
            refreshSkew: 60,
            dialect: .hermesNative,
            refreshURL: base.appendingPathComponent("auth/native/refresh")
        )
    }

    /// The Keychain account for one server's sign-in: per server, so changing the address can't
    /// send one server's tokens to another.
    nonisolated static func accountId(base: URL) -> String {
        // Scheme and host are case-insensitive; the path isn't (two proxy mounts can differ by case).
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return "hermes-dashboard:" + base.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return "hermes-dashboard:" + (components.string ?? base.absoluteString)
    }

    /// The dashboard base for whatever the user typed (`https://host`, a proxy prefix like
    /// `https://host/hermes`, trailing slash optional). Nil if it isn't http(s).
    nonisolated static func base(from text: String) -> URL? {
        var text = HermesService.withScheme(text)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        // The sign-in sends bearer tokens: plain http only on a local network or a tailnet.
        if HermesService.isUnencryptedRemote(text) { return nil }
        return url
    }

    /// `/api/ws` on the same host and prefix, ws(s) to match http(s).
    nonisolated static func webSocketURL(base: URL, ticket: String) -> URL? {
        guard var components = URLComponents(url: base.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return components.url
    }
}

/// One JSON object, passed between the socket reader and awaiting callers on the main actor.
struct HermesJSON: @unchecked Sendable {
    let object: [String: Any]
}

enum HermesGatewayError: LocalizedError, Equatable {
    case notSignedIn
    case connectFailed(String)
    case rpc(code: Int, message: String)
    case turnFailed(String)
    case disconnected
    case timedOut
    case busy

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to your Hermes web UI in Settings → Hermes."
        case .connectFailed(let detail): return "Couldn't connect to Hermes: \(detail)"
        case .rpc(_, let message): return "Hermes error: \(message)"
        case .turnFailed(let message): return "Hermes couldn't answer: \(message)"
        case .disconnected: return "The connection to Hermes dropped. Try again."
        case .timedOut: return "Hermes took too long to answer."
        case .busy: return "Hermes is still working on your last request."
        }
    }
}

@MainActor
final class HermesGatewayClient {

    static let shared = HermesGatewayClient()

    /// Put a question to the user by voice and return what they say (nil: no answer in time).
    /// Set by the voice agent.
    var askUser: ((String) async -> String?)?
    /// Drop the question `askUser` is waiting on, when Hermes withdraws its request. Set by the
    /// voice agent.
    var cancelQuestion: (() -> Void)?

    /// How long one turn may run (tools included) before we give up waiting.
    nonisolated static let turnTimeout: TimeInterval = 300

    private var settings: AppSettings { SettingsManager.shared.settings }

    private var socket: URLSessionWebSocketTask?
    private var nextId = 0
    private var pending: [String: CheckedContinuation<HermesJSON, Error>] = [:]
    private var ready: CheckedContinuation<HermesJSON, Error>?
    private var heartbeat: Task<Void, Never>?
    private var connecting: Task<Void, Error>?

    /// Runtime id of the open session on this connection (changes on every resume), and the
    /// OpenVision conversation it belongs to.
    private var runtimeSessionId: String?
    private var runtimeConversation: UUID?
    /// The turn we're waiting on: armed before prompt.submit, finished by message.complete. `id`
    /// lets a turn's timeout tell itself apart from a later turn in the same session.
    private var turn: (id: UUID, session: String, started: Bool, continuation: CheckedContinuation<String, Error>)?
    /// The server request the user is being asked about, and requests Hermes withdrew while we
    /// were asking (no reply is sent for those).
    private var askingRequestId: String?
    private var withdrawnRequests: Set<String> = []

    private init() {}

    // MARK: - Turn

    /// Ask Hermes and return its final answer. Connects, and creates or resumes the OpenVision
    /// session, as needed.
    func ask(_ text: String, imageData: Data?) async throws -> String {
        guard let base = HermesDashboard.base(from: settings.hermesDashboardURL),
              OAuthTokenStore.shared.isSignedIn(HermesDashboard.provider(base: base)) else {
            throw HermesGatewayError.notSignedIn
        }
        try await ensureConnected(base: base)
        var session = try await ensureSession()

        do {
            return try await runTurn(session: session, text: text, imageData: imageData)
        } catch HermesGatewayError.rpc(code: 4001, _) {
            // The runtime session was reaped (idle, or the backend restarted): resume and retry.
            runtimeSessionId = nil
            session = try await ensureSession()
            return try await runTurn(session: session, text: text, imageData: imageData)
        }
    }

    /// Stop the turn in progress (barge-in).
    func interrupt() async {
        if turn == nil, preparingTurn != nil {
            // Still uploading the photo: don't submit the prompt once it's done.
            preparingTurn = nil
            return
        }
        guard let current = turn, let session = runtimeSessionId else { return }
        _ = try? await call("session.interrupt", ["session_id": session], timeout: 10)
        // Hermes ends an interrupted run with message.complete, but not one that hadn't started
        // yet. Don't leave the turn armed (every request "busy") waiting for it.
        try? await Task.sleep(for: Self.interruptGrace)
        if turn?.id == current.id { finishTurn(.failure(CancellationError())) }
    }

    nonisolated static let interruptGrace: Duration = .seconds(3)

    /// A turn getting ready to submit (uploading its photo); cleared by an interrupt.
    private var preparingTurn: UUID?

    private func runTurn(session: String, text: String, imageData: Data?) async throws -> String {
        // One turn at a time: a second one would replace the first, whose caller then waits forever.
        guard turn == nil, preparingTurn == nil else { throw HermesGatewayError.busy }
        let turnId = UUID()
        preparingTurn = turnId
        defer { if preparingTurn == turnId { preparingTurn = nil } }
        if let imageData {
            _ = try await callCompatible("image.attach_bytes", [
                "session_id": session,
                "content_base64": imageData.base64EncodedString(),
                "filename": "glasses.jpg",
            ], required: ["session_id", "content_base64"], timeout: 60)
        }
        // Interrupted while the photo uploaded.
        guard preparingTurn == turnId else { throw CancellationError() }
        preparingTurn = nil
        return try await withCheckedThrowingContinuation { continuation in
            // Checked again: another turn may have started while the image was uploading.
            guard turn == nil else { return continuation.resume(throwing: HermesGatewayError.busy) }
            turn = (turnId, session, false, continuation)
            Task {
                do {
                    let result = try await submit(text, session: session)
                    NSLog("[HermesGW] prompt %@", (result.object["status"] as? String) ?? "?")
                } catch {
                    // Only this turn: after an interrupt's grace a newer turn may be running.
                    if turn?.id == turnId { finishTurn(.failure(error)) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.turnTimeout))
                // Only this turn: a timer from an earlier turn in the same session must not end a
                // later one (it did, 0.3s into a turn, five minutes after the previous one began).
                if turn?.id == turnId { finishTurn(.failure(HermesGatewayError.timedOut)) }
            }
        }
    }

    /// prompt.submit with Hermes' own voice surface: "voice-live" makes Hermes put its spoken-reply
    /// instructions (short, plain sentences, no markdown) on the model input only, so they never
    /// reach the transcript or the auto-generated chat title. A Hermes without `surface` gets our
    /// text preamble instead.
    private func submit(_ text: String, session: String) async throws -> HermesJSON {
        do {
            return try await call("prompt.submit", ["session_id": session, "text": text, "surface": "voice-live"], timeout: 30)
        } catch HermesGatewayError.rpc(code: 4000, let message) where Self.rejectedParam(message) == "surface" {
            NSLog("[HermesGW] this Hermes has no voice surface, sending the voice note in the prompt")
            return try await call("prompt.submit", ["session_id": session, "text": HermesService.voicePreamble + text], timeout: 30)
        }
    }

    private func finishTurn(_ result: Result<String, Error>) {
        guard let turn else { return }
        if case .failure(let error) = result { NSLog("[HermesGW] turn failed: %@", "\(error)") }
        self.turn = nil
        turn.continuation.resume(with: result)
    }

    // MARK: - Slash commands

    /// The command part of a spoken slash command ("slash usage", "/title Trip planning"), or nil
    /// if this isn't one. Speech recognition writes "slash" or, sometimes, a literal "/".
    nonisolated static func spokenSlashCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, words[0].lowercased().trimmingCharacters(in: .punctuationCharacters) == "slash" else { return nil }
        return words.dropFirst().joined(separator: " ")
    }

    /// Match spoken words against the server's command names: the longest run of leading words
    /// that names a command (ignoring case, spaces and punctuation, so "github PR" finds
    /// /github-pr), and the rest as its argument. `canon` maps lowercase name/alias → "/name".
    nonisolated static func matchSlashCommand(_ spoken: String, canon: [String: String]) -> (command: String, argument: String)? {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var byKey: [String: String] = [:]
        for (alias, canonical) in canon { byKey[key(alias)] = canonical }
        let words = spoken.split(separator: " ").map(String.init)
        for count in stride(from: min(words.count, 4), through: 1, by: -1) {
            if let command = byKey[key(words.prefix(count).joined())] {
                return (command, words.dropFirst(count).joined(separator: " "))
            }
        }
        return nil
    }

    private var commandCanon: [String: String]?

    /// Slash commands that only run after a spoken yes.
    nonisolated static let confirmedCommands: Set<String> = [
        "/clear", "/undo", "/retry", "/rollback", "/snapshot", "/compress", "/stop", "/pause",
        "/restart", "/update", "/yolo", "/approvals", "/quit", "/import", "/reload", "/reload-mcp",
    ]

    /// Run a spoken slash command and return what to say.
    func runSlash(_ spoken: String) async throws -> String {
        guard let base = HermesDashboard.base(from: settings.hermesDashboardURL),
              OAuthTokenStore.shared.isSignedIn(HermesDashboard.provider(base: base)) else {
            throw HermesGatewayError.notSignedIn
        }
        try await ensureConnected(base: base)
        if commandCanon == nil {
            let catalog = try await call("commands.catalog", [:], timeout: 20)
            commandCanon = catalog.object["canon"] as? [String: String] ?? [:]
        }
        let firstWord = spoken.split(separator: " ").first.map(String.init) ?? spoken
        guard let match = Self.matchSlashCommand(spoken, canon: commandCanon ?? [:]) else {
            return "Hermes has no command called \(firstWord)."
        }
        NSLog("[HermesGW] slash %@ (argument: %@)", match.command, match.argument.isEmpty ? "-" : "yes")

        if match.command == "/new" {
            // A new chat, OpenVision's way: a new History conversation gets its own Hermes chat.
            ConversationManager.shared.startNewConversation()
            ConversationContext.shared.clear()
            runtimeSessionId = nil
            return "Started a new chat."
        }

        if Self.confirmedCommands.contains(match.command) {
            // These change or throw away state (or approvals): one misheard utterance mustn't.
            let spokenName = match.command.dropFirst()
            guard let askUser else { return "Run /\(spokenName) from Hermes itself." }
            let reply = await askUser("Run \(spokenName) on Hermes? Say yes or no.")
            guard Self.isYes(reply) else { return "Okay, I didn't run \(spokenName)." }
        }

        let session = try await ensureSession()
        var argument = match.argument
        if match.command == "/model", !argument.isEmpty {
            // Spoken model ids lose their punctuation ("GPT six Luna"): map to a real id.
            let models = await modelIds(session: session)
            if let id = Self.bestModelMatch(argument, models: models) {
                NSLog("[HermesGW] model \"%@\" → %@", argument, id)
                argument = id
            } else if !models.isEmpty {
                // Better to ask again than to switch to a model the user didn't name.
                return "Hermes has no model like \(argument)."
            }
        }
        var command = argument.isEmpty ? match.command : "\(match.command) \(argument)"
        for _ in 0..<2 {
            let result = try await call("slash.exec", ["session_id": session, "command": command], timeout: 60).object
            switch result["type"] as? String {
            case "alias":
                if let target = result["target"] as? String, !target.isEmpty {
                    command = target.hasPrefix("/") ? target : "/" + target
                    continue
                }
            case "send", "skill", "prefill":
                // The command expands into a prompt (skills work this way): run it as a turn.
                if let message = result["message"] as? String, !message.isEmpty {
                    return try await runTurn(session: session, text: message, imageData: nil)
                }
            default:
                break
            }
            let parts = [result["output"], result["notice"], result["warning"]]
                .compactMap { $0 as? String }.map(Self.speakable).filter { !$0.isEmpty }
            return parts.isEmpty ? "Done." : parts.joined(separator: " ")
        }
        return "Done."
    }

    /// Model ids from signed-in providers (model.options), or none if the call fails.
    private func modelIds(session: String) async -> [String] {
        guard let result = try? await callCompatible("model.options", ["session_id": session],
                                                     required: [], timeout: 20) else { return [] }
        let providers = result.object["providers"] as? [[String: Any]] ?? []
        return providers
            .filter { ($0["authenticated"] as? Bool) != false }
            .flatMap { $0["models"] as? [String] ?? [] }
    }

    private nonisolated static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
    ]

    /// What a spoken or written id reduces to for matching: lowercase letters and digits only,
    /// with number words as digits ("GPT six Luna", "gpt-6-luna" → "gpt6luna"; "point" drops out,
    /// so "four point five" → "45" like "4.5").
    nonisolated static func idKey(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { numberWords[String($0)] ?? String($0) }
            .filter { $0 != "point" && $0 != "dot" }
            .joined()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// The model id a spoken argument means: exact on the reduced key, else the closest one if
    /// it's within a few edits (mis-hearings like "DPT" or "lunar"), else nil. Only letters may
    /// be fuzzy: the digits must match exactly, so "GPT six" can never become gpt-5.6 (it did,
    /// on a server without gpt-6-luna, before this rule).
    nonisolated static func bestModelMatch(_ spoken: String, models: [String]) -> String? {
        let target = idKey(spoken)
        guard !target.isEmpty else { return nil }
        if let exact = models.first(where: { idKey($0) == target }) { return exact }
        func digits(_ key: String) -> String { key.filter(\.isNumber) }
        let candidates = models.filter { digits(idKey($0)) == digits(target) }
        let scored = candidates.map { ($0, editDistance(idKey($0), target)) }.min { $0.1 < $1.1 }
        guard let (model, distance) = scored, distance <= max(2, target.count / 4) else { return nil }
        return model
    }

    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Command output for speech: no terminal colors, markdown markup or table rules.
    nonisolated static func speakable(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`#>|]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "-{3,}|={3,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\n\\s*", with: ". ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\. ){2,}", with: ". ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    // MARK: - Session

    /// The Hermes chat for the current OpenVision conversation. Each conversation in History
    /// (a new one starts after a few quiet minutes, or with +) has its own Hermes session, so
    /// Hermes' chat list follows OpenVision's History.
    private func ensureSession() async throws -> String {
        let conversation = ConversationManager.shared.getOrCreateCurrentConversation()
        if let runtimeSessionId, runtimeConversation == conversation.id { return runtimeSessionId }
        runtimeSessionId = nil

        let key = conversation.id.uuidString
        if let stored = settings.hermesSessions[key] {
            do {
                let result = try await callCompatible("session.resume", [
                    "session_id": stored,
                    "omit_messages": true,
                    "inline_images": false,
                ], required: ["session_id"], timeout: 30)
                if let id = result.object["session_id"] as? String {
                    adopt(id, for: conversation.id)
                    return id
                }
            } catch HermesGatewayError.rpc(code: 4007, _) {
                NSLog("[HermesGW] chat for this conversation is gone on the server, starting a new one")
            }
        }
        // No title: Hermes names the chat itself after the first turn, and we add our prefix then
        // (see "session.title" in handleEvent).
        let result = try await callCompatible("session.create", ["source": "openvision"], required: [], timeout: 30)
        guard let id = result.object["session_id"] as? String else {
            throw HermesGatewayError.turnFailed("no session id")
        }
        adopt(id, for: conversation.id)
        if let stored = result.object["stored_session_id"] as? String {
            remember(stored, for: key)
        }
        return id
    }

    private func adopt(_ runtimeId: String, for conversation: UUID) {
        runtimeSessionId = runtimeId
        runtimeConversation = conversation
    }

    /// Store a conversation → Hermes chat mapping, dropping conversations no longer in History.
    private func remember(_ storedId: String, for key: String) {
        let live = Set(ConversationManager.shared.conversations.map(\.id.uuidString))
        var sessions = settings.hermesSessions.filter { live.contains($0.key) }
        sessions[key] = storedId
        SettingsManager.shared.settings.hermesSessions = sessions
    }

    // MARK: - Connection

    private func ensureConnected(base: URL) async throws {
        // `connecting` first: `socket` is set before the handshake finishes.
        if let connecting { return try await connecting.value }
        if socket != nil { return }
        let task = Task { try await connect(base: base) }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func connect(base: URL) async throws {
        let ticket = try await mintTicket(base: base)
        guard let url = HermesDashboard.webSocketURL(base: base, ticket: ticket) else {
            throw HermesGatewayError.connectFailed("bad address")
        }
        // No Origin header: Hermes only checks Origin when one is sent.
        let socket = URLSession.shared.webSocketTask(with: URLRequest(url: url))
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        socket.resume()
        receive(on: socket)
        do {
            try await handshake(on: socket)
        } catch {
            // Don't leave a half-set-up socket for the next turn to reuse: it reconnects instead.
            if self.socket === socket { disconnect(error) }
            throw error
        }
        NSLog("[HermesGW] connected")
    }

    /// Wait for gateway.ready, then declare that we answer server requests.
    private func handshake(on socket: URLSessionWebSocketTask) async throws {
        let readyEvent: HermesJSON = try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            Task {
                try? await Task.sleep(for: .seconds(15))
                // Only this attempt's wait: after a drop and reconnect, `ready` is the new one's.
                if self.socket === socket, let ready = self.ready {
                    self.ready = nil
                    ready.resume(throwing: HermesGatewayError.connectFailed("no answer from the gateway"))
                }
            }
        }
        // Without this, every approval or question for our session fails fast server-side.
        _ = try await call("client.capabilities", ["server_requests": true], timeout: 15)
        let payload = readyEvent.object["payload"] as? [String: Any]
        if payload?["heartbeat"] as? Bool == true { startHeartbeat() }
    }

    /// POST /api/auth/ws-ticket with the access token; one forced refresh on 401.
    private func mintTicket(base: URL) async throws -> String {
        let provider = HermesDashboard.provider(base: base)
        for attempt in 0..<2 {
            let credentials = try await OAuthTokenStore.shared.freshCredentials(for: provider, force: attempt > 0)
            var request = URLRequest(url: base.appendingPathComponent("api/auth/ws-ticket"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            guard (200...299).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ticket = json["ticket"] as? String else {
                if status == 401 { throw OAuthError.authorizationExpired }
                throw HermesGatewayError.connectFailed(CloudChat.errorMessage(from: data) ?? "HTTP \(status)")
            }
            return ticket
        }
        throw OAuthError.authorizationExpired
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.socket != nil else { return }
                n += 1
                self.send(["jsonrpc": "2.0", "id": "heartbeat-\(n)", "method": "gateway.ping", "params": [:]])
            }
        }
    }

    /// Drop the connection; anything waiting fails and the next turn reconnects.
    func disconnect(_ error: Error = HermesGatewayError.disconnected) {
        commandCanon = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        heartbeat?.cancel()
        heartbeat = nil
        runtimeSessionId = nil
        if askingRequestId != nil {
            // The request died with the connection; don't let the next utterance answer it.
            askingRequestId = nil
            cancelQuestion?()
        }
        if let ready { self.ready = nil; ready.resume(throwing: error) }
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
        finishTurn(.failure(error))
    }

    // MARK: - JSON-RPC

    /// `call`, tolerating an older Hermes: params are strict there (unknown keys fail with 4000
    /// "<key>: Extra inputs are not permitted"), and optional fields like inline_images are newer
    /// than some installs. Drop the field Hermes names and retry; required keys are never dropped.
    private func callCompatible(_ method: String, _ params: [String: Any], required: Set<String>,
                                timeout: TimeInterval) async throws -> HermesJSON {
        var params = params
        for _ in 0..<4 {
            do {
                return try await call(method, params, timeout: timeout)
            } catch HermesGatewayError.rpc(code: 4000, let message) {
                guard let field = Self.rejectedParam(message), !required.contains(field),
                      params.removeValue(forKey: field) != nil else { throw HermesGatewayError.rpc(code: 4000, message: message) }
                NSLog("[HermesGW] %@: this Hermes doesn't know %@, retrying without it", method, field)
            }
        }
        return try await call(method, params, timeout: timeout)
    }

    /// The param name in Hermes' "invalid params for <method>: <name>: Extra inputs are not
    /// permitted …" error, or nil if it's some other 4000.
    nonisolated static func rejectedParam(_ message: String) -> String? {
        guard let range = message.range(of: ": Extra inputs are not permitted") else { return nil }
        let head = message[..<range.lowerBound]
        guard let colon = head.lastIndex(of: ":") else { return nil }
        let name = head[head.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.contains(" ") ? nil : name
    }

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> HermesJSON {
        guard socket != nil else { throw HermesGatewayError.disconnected }
        nextId += 1
        let id = "ov\(nextId)"
        let started = Date()
        do {
            let result: HermesJSON = try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if let waiting = self.pending.removeValue(forKey: id) {
                        waiting.resume(throwing: HermesGatewayError.timedOut)
                    }
                }
            }
            NSLog("[HermesGW] %@ ok (%.1fs)", method, Date().timeIntervalSince(started))
            return result
        } catch {
            NSLog("[HermesGW] %@ failed after %.1fs: %@", method, Date().timeIntervalSince(started), "\(error)")
            throw error
        }
    }

    private func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            if let error { NSLog("[HermesGW] send failed: %@", "\(error)") }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .failure(let error):
                    NSLog("[HermesGW] socket closed: %@", "\(error)")
                    self.disconnect()
                case .success(let message):
                    let text: String?
                    switch message {
                    case .string(let string): text = string
                    case .data(let data): text = String(data: data, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text, let data = text.data(using: .utf8),
                       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        self.handle(object)
                    }
                    self.receive(on: socket)
                }
            }
        }
    }

    // MARK: - Inbound

    private func handle(_ message: [String: Any]) {
        switch Self.classify(message) {
        case .response(let id):
            guard let waiting = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                waiting.resume(throwing: HermesGatewayError.rpc(code: error["code"] as? Int ?? 0,
                                                                message: error["message"] as? String ?? "error"))
            } else {
                waiting.resume(returning: HermesJSON(object: message["result"] as? [String: Any] ?? [:]))
            }
        case .event(let type, let params):
            handleEvent(type, params.object)
        case .serverRequest(let id, let method, let params):
            Task { await answer(id: id, method: method, params: params.object) }
        case .ignore:
            break
        }
    }

    enum Inbound {
        case response(id: String)
        case event(type: String, params: HermesJSON)
        case serverRequest(id: String, method: String, params: HermesJSON)
        case ignore
    }

    /// JSON-RPC routing: events are notifications with method "event"; any other method with an
    /// id is the server asking us something; an id with result/error and no method is a response.
    nonisolated static func classify(_ message: [String: Any]) -> Inbound {
        let id = (message["id"] as? String) ?? (message["id"] as? Int).map(String.init)
        let params = message["params"] as? [String: Any] ?? [:]
        if let method = message["method"] as? String {
            if method == "event", let type = params["type"] as? String { return .event(type: type, params: HermesJSON(object: params)) }
            if let id { return .serverRequest(id: id, method: method, params: HermesJSON(object: params)) }
            return .ignore
        }
        if let id, message["result"] != nil || message["error"] != nil { return .response(id: id) }
        return .ignore
    }

    private func handleEvent(_ type: String, _ params: [String: Any]) {
        switch type {
        case "gateway.ready":
            if let ready {
                self.ready = nil
                ready.resume(returning: HermesJSON(object: params))
            }
        case "session.title":
            // Hermes auto-titled a chat. Prefix ours so they're easy to find in Hermes' list, but
            // only once titling has settled: Hermes first sets an instant placeholder, then an LLM
            // title about a second later, and our rename (a "user" title to Hermes) would block that
            // upgrade. The event doesn't say which one it is, so wait for the last one.
            let payload = params["payload"] as? [String: Any] ?? [:]
            if let runtimeId = params["session_id"] as? String, let title = payload["title"] as? String {
                let question = ConversationManager.shared.currentConversation?.title
                scheduleRename(runtimeId, hermesTitle: title, fallback: question == "New Conversation" ? nil : question)
            }
        case "request.cancel":
            // Hermes withdrew a request (timed out, interrupted, answered elsewhere): stop asking.
            let payload = params["payload"] as? [String: Any] ?? [:]
            NSLog("[HermesGW] request withdrawn: %@", (payload["reason"] as? String) ?? "-")
            if let id = payload["id"] as? String ?? (payload["id"] as? Int).map(String.init), id == askingRequestId {
                withdrawnRequests.insert(id)
                cancelQuestion?()
            }
        case "message.start", "message.complete", "error":
            NSLog("[HermesGW] event %@ session=%@", type, (params["session_id"] as? String) ?? "-")
            handleTurnEvent(type, params)
        default:
            break   // deltas, tool progress, reasoning, usage…: the final text is in message.complete
        }
    }

    private func handleTurnEvent(_ type: String, _ params: [String: Any]) {
        switch type {
        case "message.start":
            if let current = turn, params["session_id"] as? String == current.session {
                turn?.started = true
            }
        case "message.complete":
            // message.complete also ends turns we didn't start (background notifications), so
            // only take the first one after our turn actually started.
            guard let current = turn, current.started, params["session_id"] as? String == current.session else { return }
            let payload = params["payload"] as? [String: Any] ?? [:]
            finishTurn(Self.turnResult(payload))
        case "error":
            guard let current = turn, (params["session_id"] as? String).map({ $0 == current.session }) ?? true else { return }
            let payload = params["payload"] as? [String: Any] ?? [:]
            finishTurn(.failure(HermesGatewayError.turnFailed(payload["message"] as? String ?? "error")))
        default:
            break   // deltas, tool progress, reasoning, usage…: the final text is in message.complete
        }
    }

    nonisolated static let titlePrefix = "OpenVision: "

    /// Hermes' title with our prefix, or nil if it already has it (our own rename echoing back).
    /// Hermes' auto-titler reads the model input, which on the voice surface starts with Hermes'
    /// own "[Note: this message is a delegation…]"; a title that is that note (or any bracketed
    /// tag) is replaced by `fallback`, the conversation's own title from the user's question.
    nonisolated static func prefixedTitle(_ title: String, fallback: String? = nil) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.hasPrefix(titlePrefix) else { return nil }
        if title.isEmpty || title.hasPrefix("[") {
            guard let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty else { return nil }
            return titlePrefix + fallback
        }
        return titlePrefix + title
    }

    /// How long a title must stay unchanged before we prefix it.
    nonisolated static let titleSettleDelay: Duration = .seconds(8)
    private var pendingRenames: [String: Task<Void, Never>] = [:]

    private func scheduleRename(_ runtimeId: String, hermesTitle: String, fallback: String?) {
        pendingRenames[runtimeId]?.cancel()
        pendingRenames[runtimeId] = Task { [weak self] in
            try? await Task.sleep(for: Self.titleSettleDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingRenames[runtimeId] = nil
            if let prefixed = Self.prefixedTitle(hermesTitle, fallback: fallback) {
                await self.rename(runtimeId, to: prefixed)
            }
        }
    }

    /// Best effort: an older Hermes may not have session.title, and Hermes refuses a duplicate
    /// title. Either way the chat keeps Hermes' own title.
    private func rename(_ runtimeId: String, to title: String) async {
        do {
            _ = try await call("session.title", ["session_id": runtimeId, "title": title], timeout: 15)
        } catch {
            NSLog("[HermesGW] couldn't prefix the chat title: %@", "\(error)")
        }
    }

    /// The final answer from a message.complete payload.
    nonisolated static func turnResult(_ payload: [String: Any]) -> Result<String, Error> {
        let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch payload["status"] as? String ?? "complete" {
        case "complete":
            // A run that only used tools can finish without any text.
            return .success(text.isEmpty ? "Done." : text)
        case "interrupted":
            return .failure(CancellationError())
        default:
            return .failure(HermesGatewayError.turnFailed(payload["error"] as? String ?? (text.isEmpty ? "error" : text)))
        }
    }

    // MARK: - Server → client requests

    /// Window-owned bridges: answering 4404 tells Hermes there's no Desktop window here, so the
    /// tool fails at once instead of waiting.
    nonisolated static let windowRequests: Set<String> = ["terminal.read", "preview.read", "preview.act", "window.read", "tour"]

    private func answer(id: String, method: String, params: [String: Any]) async {
        NSLog("[HermesGW] server asks: %@", method)
        switch method {
        case "approval":
            askingRequestId = id
            let choice = await approve(params)
            if askingRequestId == id { askingRequestId = nil }
            guard withdrawnRequests.remove(id) == nil else { return }
            NSLog("[HermesGW] approval answered: %@", choice)
            send(["jsonrpc": "2.0", "id": id, "result": ["choice": choice]])
        case "clarify":
            askingRequestId = id
            let answers = await clarify(params)
            if askingRequestId == id { askingRequestId = nil }
            guard withdrawnRequests.remove(id) == nil else { return }
            send(["jsonrpc": "2.0", "id": id, "result": answers.map { ["answers": $0] } ?? [:]])
        default:
            // sudo, secret, vault.*, display.install.sudo, …: never by voice.
            let code = Self.windowRequests.contains(method) ? 4404 : -32601
            send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": "not supported by OpenVision"]])
        }
    }

    private func approve(_ params: [String: Any]) async -> String {
        let choices = params["choices"] as? [String] ?? ["once", "deny"]
        guard choices.contains("once"), let askUser else { return "deny" }
        let what = (params["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (params["command"] as? String).map { "run \($0)" } ?? "use a tool"
        let reply = await askUser("Hermes wants to \(what). Should it go ahead? Say yes or no.")
        return Self.isYes(reply) ? "once" : "deny"
    }

    /// Answers keyed by question id, or nil to cancel (no one to ask, or no answer in time).
    private func clarify(_ params: [String: Any]) async -> [String: String]? {
        guard let askUser, let questions = params["questions"] as? [[String: Any]] else { return nil }
        var answers: [String: String] = [:]
        for question in questions {
            guard let qid = question["qid"] as? String, let text = question["question"] as? String else { continue }
            let options = (question["choices"] as? [String]).map { " Options: " + $0.joined(separator: ", ") + "." } ?? ""
            guard let reply = await askUser("Hermes asks: \(text)\(options)") else { return nil }
            answers[qid] = reply
        }
        return answers
    }

    /// Whether a spoken reply approves. Anything negative wins ("yes, no, don't"), and silence
    /// or an unclear answer is a no: Hermes' own rule is that silence is not consent.
    nonisolated static func isYes(_ reply: String?) -> Bool {
        guard let reply else { return false }
        let lower = reply.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let words = lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let no: Set<String> = ["no", "nope", "nah", "dont", "deny", "stop", "cancel", "not", "never"]
        if words.contains(where: no.contains) || lower.contains("don't") || lower.contains("do not") { return false }
        let yes: Set<String> = ["yes", "yeah", "yep", "sure", "ok", "okay", "allow", "approve", "approved", "proceed"]
        return words.contains(where: yes.contains) || lower.contains("go ahead") || lower.contains("do it")
    }
}
