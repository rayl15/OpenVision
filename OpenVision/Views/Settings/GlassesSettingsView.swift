// OpenVision - GlassesSettingsView.swift
// Meta Ray-Ban glasses registration and status

import SwiftUI

struct GlassesSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - State

    @State private var isRegistering: Bool = false
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        Form {
            // Registration Section
            Section {
                if glassesManager.isRegistered {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Registered")
                            .foregroundColor(.green)
                        Spacer()
                        Button("Unregister") {
                            // TODO: Implement unregister
                        }
                        .foregroundColor(.red)
                        .font(.caption)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Register with Meta AI app to access your glasses")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button {
                            register()
                        } label: {
                            HStack {
                                Spacer()
                                if isRegistering {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Opening Meta AI...")
                                } else {
                                    Image(systemName: "person.badge.plus")
                                    Text("Register App")
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRegistering)
                    }
                }

                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } header: {
                Text("Registration")
            } footer: {
                Text("Registration opens the Meta AI app where you'll grant OpenVision access to your glasses.")
            }

            // Device Status Section
            if glassesManager.isRegistered {
                Section {
                    HStack {
                        Text("Connected Devices")
                        Spacer()
                        Text("\(glassesManager.connectedDeviceCount)")
                            .foregroundColor(.secondary)
                    }

                    if let device = glassesManager.connectedDevice {
                        HStack {
                            Text("Active Device")
                            Spacer()
                            Text(device)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Streaming")
                        Spacer()
                        if glassesManager.isStreaming {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                Text("Active")
                                    .foregroundColor(.red)
                            }
                        } else {
                            Text("Inactive")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Device Status")
                }

                // Camera Controls
                Section {
                    Button {
                        Task {
                            await glassesManager.startStreaming()
                        }
                    } label: {
                        Label("Start Camera Stream", systemImage: "video")
                    }
                    .disabled(glassesManager.isStreaming)

                    Button {
                        Task {
                            await glassesManager.stopStreaming()
                        }
                    } label: {
                        Label("Stop Camera Stream", systemImage: "video.slash")
                    }
                    .disabled(!glassesManager.isStreaming)

                    Button {
                        Task {
                            await glassesManager.capturePhoto()
                        }
                    } label: {
                        Label("Capture Photo", systemImage: "camera")
                    }
                    .disabled(!glassesManager.isStreaming)
                } header: {
                    Text("Camera Controls")
                } footer: {
                    Text("Use camera controls to test glasses connectivity.")
                }
            }

            // Help Section
            Section {
                Link(destination: URL(string: "https://developer.meta.com/docs/wearables")!) {
                    HStack {
                        Text("Meta Wearables Documentation")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    TroubleshootingView()
                } label: {
                    Text("Troubleshooting")
                }
            } header: {
                Text("Help")
            }
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Methods

    private func register() {
        isRegistering = true
        errorMessage = nil

        Task {
            do {
                try await glassesManager.register()
                await MainActor.run {
                    isRegistering = false
                }
            } catch {
                await MainActor.run {
                    isRegistering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Troubleshooting View

struct TroubleshootingView: View {
    var body: some View {
        List {
            Section("Registration Issues") {
                TroubleshootingItem(
                    title: "Meta AI app not opening",
                    solution: "Make sure Meta AI app is installed and you're signed in."
                )
                TroubleshootingItem(
                    title: "Registration fails",
                    solution: "Enable Developer Mode in Meta AI app settings, then try again."
                )
                TroubleshootingItem(
                    title: "App not appearing in Meta AI",
                    solution: "Check that your Meta App ID is correctly configured."
                )
            }

            Section("Connection Issues") {
                TroubleshootingItem(
                    title: "No devices found",
                    solution: "Ensure your glasses are paired with your iPhone via Bluetooth."
                )
                TroubleshootingItem(
                    title: "Streaming not starting",
                    solution: "Close other apps that might be using the glasses camera."
                )
                TroubleshootingItem(
                    title: "Poor video quality",
                    solution: "Make sure you have good lighting and stable Bluetooth connection."
                )
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TroubleshootingItem: View {
    let title: String
    let solution: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(solution)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        GlassesSettingsView()
            .environmentObject(GlassesManager.shared)
    }
}
