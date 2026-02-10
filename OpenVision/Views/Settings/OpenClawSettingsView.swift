// OpenVision - OpenClawSettingsView.swift
// OpenClaw gateway URL and auth token configuration

import SwiftUI

struct OpenClawSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var gatewayURL: String = ""
    @State private var authToken: String = ""
    @State private var isTestingConnection: Bool = false
    @State private var connectionTestResult: ConnectionTestResult?

    enum ConnectionTestResult {
        case success
        case failure(String)
    }

    // MARK: - Body

    var body: some View {
        Form {
            // Connection Settings
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gateway URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("wss://openclaw.example.com", text: $gatewayURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Auth Token")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Your authentication token", text: $authToken)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Enter your OpenClaw gateway WebSocket URL and authentication token.")
            }

            // Test Connection
            Section {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        Spacer()
                        if isTestingConnection {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Testing...")
                        } else {
                            Text("Test Connection")
                        }
                        Spacer()
                    }
                }
                .disabled(gatewayURL.isEmpty || authToken.isEmpty || isTestingConnection)

                if let result = connectionTestResult {
                    HStack {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connection successful!")
                                .foregroundColor(.green)
                        case .failure(let message):
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
            }

            // Help
            Section {
                Link(destination: URL(string: "https://github.com/openclaw/openclaw")!) {
                    HStack {
                        Text("Get OpenClaw")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

                Link(destination: URL(string: "https://openclaw.ai/docs/setup")!) {
                    HStack {
                        Text("Setup Guide")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("OpenClaw runs on your local machine or cloud server. It provides 56+ tools for task automation.")
            }
        }
        .navigationTitle("OpenClaw")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            gatewayURL = settingsManager.settings.openClawGatewayURL
            authToken = settingsManager.settings.openClawAuthToken
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
        settingsManager.settings.openClawGatewayURL = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.openClawAuthToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.saveNow()
    }

    private func testConnection() {
        isTestingConnection = true
        connectionTestResult = nil

        // TODO: Implement actual WebSocket connection test
        // For now, simulate a test
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            await MainActor.run {
                isTestingConnection = false

                if gatewayURL.hasPrefix("wss://") || gatewayURL.hasPrefix("ws://") {
                    connectionTestResult = .success
                } else {
                    connectionTestResult = .failure("Invalid URL format. Use wss:// or ws://")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        OpenClawSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
