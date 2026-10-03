// OpenVision - HermesTests.swift
// Hermes server address handling, the plain-http warning, and the capabilities check.

import XCTest
@testable import OpenVision

final class HermesTests: XCTestCase {

    // MARK: - Server address

    func testAPIBaseAcceptsCommonForms() {
        let expected = "https://hermes.example.com/v1"
        for input in ["https://hermes.example.com", "https://hermes.example.com/", "https://hermes.example.com/v1",
                      " https://hermes.example.com/v1/ "] {
            XCTAssertEqual(HermesService.apiBase(from: input)?.absoluteString, expected, input)
        }
    }

    func testAPIBaseKeepsPortAndProfilePrefix() {
        XCTAssertEqual(HermesService.apiBase(from: "http://100.101.102.103:8642")?.absoluteString,
                       "http://100.101.102.103:8642/v1")
        XCTAssertEqual(HermesService.apiBase(from: "https://hermes.example.com/p/work")?.absoluteString,
                       "https://hermes.example.com/p/work/v1")
    }

    func testAddressWithoutSchemeGetsOne() {
        XCTAssertEqual(HermesService.apiBase(from: "hermes.example.com")?.absoluteString, "https://hermes.example.com/v1")
        XCTAssertEqual(HermesService.apiBase(from: "myhost.tailnet.ts.net")?.absoluteString, "https://myhost.tailnet.ts.net/v1")
        XCTAssertEqual(HermesService.apiBase(from: " 100.88.1.2:8642 ")?.absoluteString, "http://100.88.1.2:8642/v1")
        XCTAssertEqual(HermesService.apiBase(from: "192.168.1.20:8642/p/work")?.absoluteString, "http://192.168.1.20:8642/p/work/v1")
        XCTAssertEqual(HermesDashboard.base(from: "hermes.example.com/hermes")?.absoluteString, "https://hermes.example.com/hermes")
        XCTAssertEqual(HermesService.withScheme("http://8.8.8.8"), "http://8.8.8.8", "a typed scheme is kept")
    }

    func testAPIBaseRejectsNonHTTP() {
        XCTAssertNil(HermesService.apiBase(from: ""))
        XCTAssertNil(HermesService.apiBase(from: "ftp://hermes.example.com"))
    }

    // MARK: - Plain-http warning

    func testWarnsOnlyForPlainHTTPOverTheInternet() {
        XCTAssertTrue(HermesService.isUnencryptedRemote("http://hermes.example.com"))
        XCTAssertTrue(HermesService.isUnencryptedRemote("http://203.0.113.7:8642"))
        XCTAssertFalse(HermesService.isUnencryptedRemote("https://hermes.example.com"))
        XCTAssertFalse(HermesService.isUnencryptedRemote("http://192.168.1.20:8642"))
        XCTAssertFalse(HermesService.isUnencryptedRemote("http://10.0.0.5:8642"))
        XCTAssertFalse(HermesService.isUnencryptedRemote("http://100.88.1.2:8642"), "Tailscale address")
        XCTAssertFalse(HermesService.isUnencryptedRemote("http://server.tail1234.ts.net:8642"))
        XCTAssertFalse(HermesService.isUnencryptedRemote("http://mac-mini.local:8642"))
    }

    // MARK: - Capabilities

    func testCapabilitiesIdentifyHermes() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "object": "hermes.api_server.capabilities", "platform": "hermes-agent", "model": "work",
        ])
        XCTAssertEqual(HermesService.parseCapabilities(json), HermesService.ServerInfo(model: "work"))
    }

    func testOtherOpenAIServersAreNotHermes() throws {
        let json = try JSONSerialization.data(withJSONObject: ["object": "list", "data": []])
        XCTAssertNil(HermesService.parseCapabilities(json))
    }

    // MARK: - Web UI sign-in (native flow)

    private let dashboard = URL(string: "https://hermes.example.com/hermes")!

    func testNativeAuthorizeURLHasOnlyPKCEParams() {
        let provider = HermesDashboard.provider(base: dashboard)
        let url = OAuthClient.authorizeURL(for: provider, challenge: "CH", state: "ST")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://hermes.example.com/hermes/auth/native/authorize?"))
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name))
        XCTAssertEqual(names, ["code_challenge", "code_challenge_method", "redirect_uri", "state"])
        XCTAssertTrue(provider.redirectURI.hasPrefix("http://127.0.0.1:"), "Hermes rejects localhost")
    }

    func testNativeTokensUseAbsoluteExpiry() throws {
        let provider = HermesDashboard.provider(base: dashboard)
        let json = try JSONSerialization.data(withJSONObject: [
            "access_token": "AT", "refresh_token": "RT", "token_type": "Bearer", "expires_at": 2_000_000_000,
        ])
        let creds = try OAuthClient.credentials(from: json, provider: provider, previous: nil)
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 2_000_000_000 - provider.refreshSkew))
        XCTAssertEqual(creds.refreshToken, "RT")
    }

    func testEachServerHasItsOwnSignIn() {
        let other = HermesDashboard.provider(base: URL(string: "https://other.example.com")!)
        XCTAssertNotEqual(HermesDashboard.provider(base: dashboard).id, other.id,
                          "a changed address must not reuse another server's tokens")
        XCTAssertEqual(HermesDashboard.provider(base: dashboard).id,
                       HermesDashboard.provider(base: URL(string: "HTTPS://HERMES.example.com/hermes")!).id)
        XCTAssertNotEqual(HermesDashboard.provider(base: dashboard).id,
                          HermesDashboard.provider(base: URL(string: "https://hermes.example.com/Hermes")!).id,
                          "paths are case-sensitive")
    }

    func testExpiredHermesRefreshSignsOut() {
        let body = Data(#"{"error":"session_expired","detail":"Refresh token expired or invalid; start a new sign-in."}"#.utf8)
        XCTAssertTrue(OAuthClient.isRevoked(status: 401, errorCode: OAuthClient.tokenErrorCode(body)))
    }

    func testDashboardBaseAndWebSocketURL() {
        let base = HermesDashboard.base(from: " https://hermes.example.com/hermes/ ")
        XCTAssertEqual(base?.absoluteString, "https://hermes.example.com/hermes")
        XCTAssertEqual(HermesDashboard.webSocketURL(base: base!, ticket: "t1")?.absoluteString,
                       "wss://hermes.example.com/hermes/api/ws?ticket=t1")
        XCTAssertEqual(HermesDashboard.webSocketURL(base: URL(string: "http://100.88.1.2:9119")!, ticket: "t")?.absoluteString,
                       "ws://100.88.1.2:9119/api/ws?ticket=t")
        XCTAssertNil(HermesDashboard.base(from: "http://hermes.example.com"), "no tokens over plain http on the internet")
        XCTAssertNotNil(HermesDashboard.base(from: "http://192.168.1.20:9119"))
    }

    func testAppSignInNeedsGatedDashboardWithNativeFlow() {
        XCTAssertNil(HermesService.appSignInProblem(status: ["auth_required": true, "auth_flows": ["cookie", "native_pkce"]]))
        XCTAssertNotNil(HermesService.appSignInProblem(status: ["auth_required": false]))
        XCTAssertNotNil(HermesService.appSignInProblem(status: ["auth_required": true, "auth_flows": ["cookie"]]))
    }

    // MARK: - Gateway protocol

    func testClassifiesResponsesEventsAndServerRequests() {
        guard case .response(let id) = HermesGatewayClient.classify(["jsonrpc": "2.0", "id": "ov3", "result": [:]]) else {
            return XCTFail("response")
        }
        XCTAssertEqual(id, "ov3")
        let event: [String: Any] = ["jsonrpc": "2.0", "method": "event",
                                    "params": ["type": "message.complete", "session_id": "s1", "payload": ["text": "Hi"]]]
        guard case .event(let type, _) = HermesGatewayClient.classify(event) else { return XCTFail("event") }
        XCTAssertEqual(type, "message.complete")
        let request: [String: Any] = ["jsonrpc": "2.0", "id": "srq-abc", "method": "clarify",
                                      "params": ["questions": [["qid": "q1", "question": "Which repo?"]]]]
        guard case .serverRequest(let rid, let method, let params) = HermesGatewayClient.classify(request) else {
            return XCTFail("server request")
        }
        XCTAssertEqual(rid, "srq-abc")
        XCTAssertEqual(method, "clarify")
        XCTAssertEqual((params.object["questions"] as? [[String: Any]])?.count, 1, "nested arrays must survive")
    }

    func testFindsTheParamAnOlderHermesRejects() {
        // Verbatim from a Hermes server older than the inline_images param.
        let message = "invalid params for session.resume: inline_images: Extra inputs are not permitted — the client and the Hermes backend are out of sync (different versions); run `hermes update` and restart both"
        XCTAssertEqual(HermesGatewayClient.rejectedParam(message), "inline_images")
        XCTAssertNil(HermesGatewayClient.rejectedParam("invalid params for session.resume: session_id: Field required"))
    }

    func testChatTitlesGetThePrefixOnce() {
        XCTAssertEqual(HermesGatewayClient.prefixedTitle("Checking server disk space"), "OpenVision: Checking server disk space")
        XCTAssertNil(HermesGatewayClient.prefixedTitle("OpenVision: Checking server disk space"), "our own rename echoing back")
        XCTAssertNil(HermesGatewayClient.prefixedTitle("  "))
    }

    func testLeakedVoiceNoteTitleFallsBackToTheQuestion() {
        // What a Hermes server actually titled a voice-surface chat.
        let leaked = "[Note: this message is a delegation from a live spoken conversation."
        XCTAssertEqual(HermesGatewayClient.prefixedTitle(leaked, fallback: "What's the capital of Portugal"),
                       "OpenVision: What's the capital of Portugal")
        XCTAssertNil(HermesGatewayClient.prefixedTitle(leaked, fallback: nil), "keep Hermes' title rather than invent one")
        XCTAssertEqual(HermesGatewayClient.prefixedTitle("Capital of Portugal", fallback: "What's the capital"),
                       "OpenVision: Capital of Portugal", "a real Hermes title wins")
    }

    // MARK: - Slash commands

    func testRecognizesSpokenSlashCommands() {
        XCTAssertEqual(HermesGatewayClient.spokenSlashCommand("Slash usage"), "usage")
        XCTAssertEqual(HermesGatewayClient.spokenSlashCommand("/title Trip planning"), "title Trip planning")
        XCTAssertNil(HermesGatewayClient.spokenSlashCommand("What's the slash for in URLs"))
        XCTAssertNil(HermesGatewayClient.spokenSlashCommand("slash"))
    }

    func testMatchesSpokenWordsToCatalogNames() {
        let canon = ["/usage": "/usage", "/title": "/title", "/github": "/github",
                     "/github-pr": "/github-pr", "/new": "/new", "/reset": "/new"]
        XCTAssertEqual(HermesGatewayClient.matchSlashCommand("github PR", canon: canon)?.command, "/github-pr", "longest name wins")
        XCTAssertEqual(HermesGatewayClient.matchSlashCommand("github issues", canon: canon)?.command, "/github")
        let title = HermesGatewayClient.matchSlashCommand("Title Trip planning", canon: canon)
        XCTAssertEqual(title?.command, "/title")
        XCTAssertEqual(title?.argument, "Trip planning")
        XCTAssertEqual(HermesGatewayClient.matchSlashCommand("reset", canon: canon)?.command, "/new", "aliases resolve")
        XCTAssertNil(HermesGatewayClient.matchSlashCommand("banana", canon: canon))
    }

    func testSpokenModelNamesFindTheRealId() {
        let models = ["gpt-6-luna", "gpt-6.1-sol", "gpt-5.5", "grok-4.20-non-reasoning", "claude-sonnet-5"]
        // Verbatim from the phone's speech recognition.
        XCTAssertEqual(HermesGatewayClient.bestModelMatch("GPT six Luna", models: models), "gpt-6-luna")
        XCTAssertEqual(HermesGatewayClient.bestModelMatch("DPT – six – Luna", models: models), "gpt-6-luna")
        XCTAssertEqual(HermesGatewayClient.bestModelMatch("GPT six lunar", models: models), "gpt-6-luna")
        XCTAssertEqual(HermesGatewayClient.bestModelMatch("GPT five point five", models: models), "gpt-5.5")
        XCTAssertEqual(HermesGatewayClient.bestModelMatch("Claude Sonnet five", models: models), "claude-sonnet-5")
        XCTAssertNil(HermesGatewayClient.bestModelMatch("banana bread", models: models), "nothing close")
        // Verbatim regression from a server that had gpt-5.6-luna but no gpt-6-luna.
        XCTAssertNil(HermesGatewayClient.bestModelMatch("GPT six lunar", models: ["gpt-5.6-luna", "gpt-5.5"]),
                     "versions are never fuzzy")
    }

    func testCommandOutputIsSpeakable() {
        let output = "\u{1B}[1m**Usage**\u{1B}[0m\n---\n| Tokens | 1,200 |\n`gpt-6`"
        let spoken = HermesGatewayClient.speakable(output)
        XCTAssertFalse(spoken.contains("*") || spoken.contains("|") || spoken.contains("`") || spoken.contains("\u{1B}"))
        XCTAssertTrue(spoken.contains("Usage") && spoken.contains("1,200") && spoken.contains("gpt-6"))
    }

    func testTurnResult() {
        XCTAssertEqual(try HermesGatewayClient.turnResult(["text": " Done. ", "status": "complete"]).get(), "Done.")
        XCTAssertEqual(try HermesGatewayClient.turnResult(["text": "", "status": "complete"]).get(), "Done.",
                       "a tool-only run has no text")
        XCTAssertThrowsError(try HermesGatewayClient.turnResult(["text": "", "status": "error", "error": "model down"]).get())
        XCTAssertThrowsError(try HermesGatewayClient.turnResult(["text": "partial", "status": "interrupted"]).get())
    }

    func testSpokenApproval() {
        XCTAssertTrue(HermesGatewayClient.isYes("Yes"))
        XCTAssertTrue(HermesGatewayClient.isYes("yeah go ahead"))
        XCTAssertFalse(HermesGatewayClient.isYes("no"))
        XCTAssertFalse(HermesGatewayClient.isYes("don't do that"))
        XCTAssertFalse(HermesGatewayClient.isYes("Don\u{2019}t"))
        XCTAssertFalse(HermesGatewayClient.isYes("yes, no wait"), "any no wins")
        XCTAssertFalse(HermesGatewayClient.isYes("what's the weather"), "unclear is a no")
        XCTAssertFalse(HermesGatewayClient.isYes(nil), "silence is not consent")
        for yes in ["sure", "OK", "okay", "allow it", "approve", "proceed", "yep", "do it"] {
            XCTAssertTrue(HermesGatewayClient.isYes(yes), yes)
        }
        for no in ["nope", "nah", "cancel", "deny", "stop", "never", "do not run it", "not now"] {
            XCTAssertFalse(HermesGatewayClient.isYes(no), no)
        }
    }

    func testCommandsThatDiscardStateNeedAYes() {
        for command in ["/clear", "/undo", "/rollback", "/yolo", "/restart"] {
            XCTAssertTrue(HermesGatewayClient.confirmedCommands.contains(command), command)
        }
        XCTAssertFalse(HermesGatewayClient.confirmedCommands.contains("/usage"))
    }

    // MARK: - Prompt

    func testPromptAsksForShortSpokenAnswersAndKeepsCustomInstructions() {
        let prompt = HermesService.systemPrompt(custom: "Call me Rafa.")
        XCTAssertTrue(prompt.contains("1-3 short sentences"))
        XCTAssertTrue(prompt.hasSuffix("Call me Rafa."))
        XCTAssertFalse(HermesService.systemPrompt(custom: "  ").contains("\n\n"))
    }
}
