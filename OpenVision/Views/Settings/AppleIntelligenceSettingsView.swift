// OpenVision - AppleIntelligenceSettingsView.swift
// Status screen for the on-device Apple Foundation Models backend. No key or download —
// just shows whether Apple Intelligence is available on this device.

import SwiftUI

struct AppleIntelligenceSettingsView: View {
    @ObservedObject private var apple = AppleFoundationService.shared
    @State private var status: String?   // nil = available

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: status == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status == nil ? .green : .orange)
                    Text(status == nil ? "Ready" : "Unavailable")
                        .foregroundStyle(status == nil ? .green : .orange)
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Apple's on-device model — private, offline, no download and no API cost. Requires iOS 26+ on an Apple-Intelligence device (iPhone 15 Pro and newer).")
            }

            Section {
                Label("Private & on-device — nothing leaves your phone", systemImage: "lock.fill")
                Label("No multi-GB download — managed by iOS", systemImage: "internaldrive")
                Label("Text only — camera commands use a cloud backend", systemImage: "text.bubble")
            } header: {
                Text("About")
            } footer: {
                Text("Supports the same hands-free commands as Local Gemma: face recognition and web search, routed on-device.")
            }
        }
        .navigationTitle("Apple Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = apple.availabilityMessage }
    }
}

#Preview {
    NavigationStack { AppleIntelligenceSettingsView() }
}
