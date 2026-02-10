// OpenVision - AIBackendSettingsView.swift
// AI backend selection and configuration

import SwiftUI

struct AIBackendSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - Body

    var body: some View {
        Form {
            // Backend Selection
            Section {
                ForEach(AIBackendType.allCases, id: \.self) { backend in
                    Button {
                        settingsManager.settings.aiBackend = backend
                    } label: {
                        HStack {
                            Image(systemName: backend.icon)
                                .foregroundColor(.blue)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(backend.displayName)
                                    .foregroundColor(.primary)
                                Text(backend.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if settingsManager.settings.aiBackend == backend {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("Choose Your AI")
            } footer: {
                Text("OpenClaw offers more tools and privacy. Gemini Live has lower latency.")
            }

            // Backend Configuration Links
            Section {
                NavigationLink {
                    OpenClawSettingsView()
                } label: {
                    HStack {
                        Label("OpenClaw Settings", systemImage: "terminal")
                        Spacer()
                        configurationBadge(configured: settingsManager.settings.isOpenClawConfigured)
                    }
                }

                NavigationLink {
                    GeminiSettingsView()
                } label: {
                    HStack {
                        Label("Gemini Settings", systemImage: "waveform")
                        Spacer()
                        configurationBadge(configured: settingsManager.settings.isGeminiConfigured)
                    }
                }
            } header: {
                Text("Configuration")
            }
        }
        .navigationTitle("AI Backend")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func configurationBadge(configured: Bool) -> some View {
        if configured {
            HStack(spacing: 4) {
                Text("Configured")
                    .font(.caption)
                    .foregroundColor(.green)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        } else {
            HStack(spacing: 4) {
                Text("Not configured")
                    .font(.caption)
                    .foregroundColor(.orange)
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
            }
        }
    }
}

#Preview {
    NavigationStack {
        AIBackendSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
