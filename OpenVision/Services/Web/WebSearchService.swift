// OpenVision - WebSearchService.swift
// Free web search via DuckDuckGo — no API key.
//
// Two-stage: (1) the Instant Answer API for clean facts/definitions/calculations, then
// (2) the real search endpoint (html.duckduckgo.com) parsed for result snippets, which DOES
// carry live/current results (news, scores, etc.). The caller (Gemma) summarizes the snippets.
//
// Note: stage 2 parses HTML from an unofficial endpoint, so it can rate-limit or change format.
// It's the same approach most "free DuckDuckGo" integrations use.

import Foundation

enum WebSearchService {

    /// Returns a text blob of search findings for `query`, or "" if nothing was found.
    static func search(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 1) Tavily (if configured) — real live content, built for LLMs. Best for news/prices/scores.
        if let tavily = await tavilySearch(trimmed), !tavily.isEmpty {
            return tavily
        }
        // 2) DuckDuckGo Instant Answer — clean facts / definitions / math (no key).
        if let instant = await instantAnswer(trimmed), !instant.isEmpty {
            return instant
        }
        // 3) DuckDuckGo HTML result snippets (no key; weak for live data).
        return await htmlResults(trimmed)
    }

    // MARK: - Tavily (primary when a key is set)

    private static func tavilySearch(_ query: String) async -> String? {
        let key = await MainActor.run { SettingsManager.shared.settings.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !key.isEmpty, let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        let body: [String: Any] = [
            "api_key": key,
            "query": query,
            "search_depth": "basic",
            "max_results": 5,
            "include_answer": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[OV] Tavily unavailable (HTTP %d)", (response as? HTTPURLResponse)?.statusCode ?? 0)
                return nil
            }
            var parts: [String] = []
            // Tavily's synthesized answer is the cleanest thing to hand the model.
            if let answer = json["answer"] as? String, !answer.isEmpty { parts.append(answer) }
            // Plus a few supporting result snippets.
            if let results = json["results"] as? [[String: Any]] {
                for r in results.prefix(4) {
                    guard let content = (r["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { continue }
                    let title = (r["title"] as? String) ?? ""
                    parts.append(title.isEmpty ? content : "\(title): \(content)")
                }
            }
            let combined = parts.joined(separator: "\n")
            if !combined.isEmpty {
                NSLog("[OV] Tavily hit: %d chars (%d results) for \"%@\"", combined.count, (json["results"] as? [[String: Any]])?.count ?? 0, query)
            }
            return combined.isEmpty ? nil : combined
        } catch {
            NSLog("[OV] Tavily error: %@", "\(error)")
            return nil
        }
    }

    // MARK: - Stage 1: Instant Answer API

    private static func instantAnswer(_ query: String) async -> String? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1") else {
            return nil
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let answer = json["Answer"] as? String, !answer.isEmpty { return answer }
            if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
                let source = json["AbstractSource"] as? String ?? ""
                return source.isEmpty ? abstract : "\(abstract) (via \(source))"
            }
            if let topics = json["RelatedTopics"] as? [[String: Any]] {
                let summaries = topics.prefix(3).compactMap { $0["Text"] as? String }.filter { !$0.isEmpty }
                if !summaries.isEmpty { return summaries.joined(separator: ". ") }
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Stage 2: real search results (HTML)

    private static func htmlResults(_ query: String) async -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return ""
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // A browser User-Agent is required — the endpoint returns empty/blocked without one.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                NSLog("[OV] web search (html): unavailable (HTTP %d)", (response as? HTTPURLResponse)?.statusCode ?? 0)
                return ""
            }
            let snippets = parseSnippets(from: html, limit: 5)
            if snippets.isEmpty {
                NSLog("[OV] web search (html): no snippets parsed for \"%@\"", query)
                return ""
            }
            return snippets.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        } catch {
            NSLog("[OV] web search (html) failed: %@", "\(error)")
            return ""
        }
    }

    /// Extract the `result__snippet` text blocks from DuckDuckGo's HTML results page.
    private static func parseSnippets(from html: String, limit: Int) -> [String] {
        // Snippets look like: <a class="result__snippet" ...> TEXT </a>
        let pattern = "class=\"result__snippet\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [String] = []
        for match in regex.matches(in: html, options: [], range: range) {
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { continue }
            let clean = stripHTML(String(html[r]))
            if clean.count > 20 { results.append(clean) }   // skip empty/tiny fragments
            if results.count >= limit { break }
        }
        return results
    }

    /// Strip HTML tags and decode the common entities DuckDuckGo emits.
    private static func stripHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#x27;": "'", "&#39;": "'", "&#x2F;": "/", "&nbsp;": " "]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
