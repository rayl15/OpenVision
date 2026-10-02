// OpenVision - GrokSettingsView.swift
// xAI Grok backend configuration: API key, or SuperGrok subscription sign-in.

import SwiftUI

struct GrokSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    // Seeded from saved settings so the model-list task doesn't start against defaults and restart.
    @State private var authMode = SettingsManager.shared.settings.grokAuthMode
    @State private var apiKey = SettingsManager.shared.settings.grokAPIKey
    @State private var model = SettingsManager.shared.settings.grokModel

    @State private var isSignedIn = OAuthTokenStore.shared.isSignedIn(GrokService.provider)
    @State private var isSigningIn = false
    @State private var models: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Connect With", selection: $authMode) {
                    ForEach(GrokAuthMode.allCases) { mode in
                        ConnectMethodRow(title: mode.displayName, summary: mode.summary, icon: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Connect With")
            }

            switch authMode {
            case .apiKey: apiKeySection
            case .superGrok: accountSection
            }

            Section {
                if models.isEmpty {
                    TextField("Model", text: $model)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Non-reasoning models answer fastest, which matters for voice.")
            }

            if authMode == .apiKey {
                Section {
                    Link(destination: URL(string: "https://console.x.ai")!) {
                        HStack {
                            Text("Get API Key")
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Help")
                }
            }
        }
        .navigationTitle("Grok")
        .navigationBarTitleDisplayMode(.inline)
        // Reload when the sign-in method or state changes (and when a typed key is submitted).
        .task(id: "\(authMode.rawValue)|\(isSignedIn)") { await loadModels() }
        .onDisappear { saveSettings() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveSettings(); dismiss() }
            }
        }
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("xai-…", text: $apiKey)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await loadModels() } }
            }
        } header: {
            Text("Authentication")
        } footer: {
            if apiKey.isEmpty {
                Label("Required for Grok mode", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else if let errorMessage {
                // The key is saved but xAI rejected it (or couldn't be reached).
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else {
                Label("API key configured", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.caption)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if isSignedIn {
                Label("Signed in to SuperGrok", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Button("Sign Out", role: .destructive) {
                    OAuthTokenStore.shared.signOut(GrokService.provider)
                    isSignedIn = false
                    models = []
                }
            } else {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in with SuperGrok")
                        Spacer()
                        if isSigningIn { ProgressView() }
                    }
                }
                .disabled(isSigningIn)
            }
        } header: {
            Text("Account")
        } footer: {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else {
                Text("Signs in the same way as the Grok CLI, then uses xAI's public API with your plan.")
            }
        }
    }

    /// The live list, plus the saved model if the server no longer lists it (so the Picker
    /// always has a matching tag).
    private var modelChoices: [String] {
        models.contains(model) ? models : [model] + models
    }

    // MARK: - Actions

    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            try await OAuthSignIn.signIn(GrokService.provider)
            isSignedIn = true
        } catch OAuthError.cancelled {
            // User closed the sheet — nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadModels() async {
        // Requests use the saved credential, so save what's on screen first.
        saveSettings()
        guard settingsManager.settings.isGrokConfigured else { models = []; errorMessage = nil; return }
        do {
            models = try await GrokService.fetchModels()
            errorMessage = nil
        } catch is CancellationError {
            // SwiftUI restarted the task (the credential changed) — not a failure.
        } catch let error as URLError where error.code == .cancelled {
            // Same, surfaced by URLSession.
        } catch {
            models = []
            errorMessage = error.localizedDescription
            if authMode == .superGrok {
                isSignedIn = OAuthTokenStore.shared.isSignedIn(GrokService.provider)
            }
        }
    }

    private func saveSettings() {
        settingsManager.settings.grokAuthMode = authMode
        settingsManager.settings.grokAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.grokModel = trimmedModel.isEmpty ? GrokService.defaultModel : trimmedModel
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        GrokSettingsView().environmentObject(SettingsManager.shared)
    }
}
