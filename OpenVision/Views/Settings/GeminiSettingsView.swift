// OpenVision - GeminiSettingsView.swift
// Gemini Live API key configuration

import SwiftUI

struct GeminiSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var apiKey: String = ""
    @State private var videoFPS: Int = 1

    // MARK: - Body

    var body: some View {
        Form {
            // API Key
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Your Gemini API key", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Authentication")
            } footer: {
                if apiKey.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Required for Gemini Live mode")
                            .foregroundColor(.orange)
                    }
                    .font(.caption)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API key configured")
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                }
            }

            // Video Settings
            Section {
                Picker("Video Frame Rate", selection: $videoFPS) {
                    Text("1 FPS (Recommended)").tag(1)
                    Text("2 FPS").tag(2)
                    Text("5 FPS").tag(5)
                }
            } header: {
                Text("Video Streaming")
            } footer: {
                Text("Higher frame rates use more bandwidth and API quota. 1 FPS is recommended for most use cases.")
            }

            // Help
            Section {
                Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                    HStack {
                        Text("Get API Key")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

                Link(destination: URL(string: "https://ai.google.dev/gemini-api/docs/live-api")!) {
                    HStack {
                        Text("Gemini Live Documentation")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Gemini Live provides real-time voice and vision AI with native audio responses.")
            }

            // Info
            Section {
                HStack {
                    Text("Input Audio")
                    Spacer()
                    Text("16kHz PCM")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Output Audio")
                    Spacer()
                    Text("24kHz PCM")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Video Format")
                    Spacer()
                    Text("JPEG @ \(videoFPS) FPS")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Technical Details")
            }
        }
        .navigationTitle("Gemini Live")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = settingsManager.settings.geminiAPIKey
            videoFPS = settingsManager.settings.geminiVideoFPS
        }
        .onDisappear {
            saveSettings()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveSettings()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Methods

    private func saveSettings() {
        settingsManager.settings.geminiAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.geminiVideoFPS = videoFPS
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        GeminiSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
