// OpenVision - WebSearchSettingsView.swift
// Configure the web-search provider. Tavily (free tier) returns real live content for the
// assistant to summarize; DuckDuckGo is the keyless fallback.

import SwiftUI

struct WebSearchSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var apiKey: String = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tavily API Key")
                        .font(.caption).foregroundColor(.secondary)
                    SecureField("tvly-…", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Tavily (recommended)")
            } footer: {
                if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("No key — web search falls back to DuckDuckGo, which is weak for live news, prices, and scores.", systemImage: "info.circle")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Label("Tavily configured — live web content enabled.", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            }

            Section {
                Link(destination: URL(string: "https://app.tavily.com")!) {
                    HStack {
                        Text("Get a free Tavily key")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Tavily is a search API built for AI assistants — it returns real, current content (news, prices, scores) rather than just links, which is what lets the model actually answer live questions. The free tier covers everyday use. When set, it's the primary web-search source; DuckDuckGo stays the keyless fallback.")
            }
        }
        .navigationTitle("Web Search")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { apiKey = settingsManager.settings.tavilyAPIKey }
        .onDisappear { save() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
    }

    private func save() {
        settingsManager.settings.tavilyAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        WebSearchSettingsView().environmentObject(SettingsManager.shared)
    }
}
