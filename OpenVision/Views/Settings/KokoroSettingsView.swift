// OpenVision - KokoroSettingsView.swift
// Download / manage the on-device Kokoro neural-TTS model.

import SwiftUI

struct KokoroSettingsView: View {
    @ObservedObject private var kokoro = KokoroTTSService.shared
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var modelSizeBytes: Int64 = 0

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: modelSizeBytes, countStyle: .file)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: kokoro.isModelReady ? "checkmark.seal.fill" : "arrow.down.circle")
                        .foregroundStyle(kokoro.isModelReady ? .green : .orange)
                    Text(kokoro.isModelReady ? "Model ready" : "Not downloaded")
                        .foregroundStyle(kokoro.isModelReady ? .green : .primary)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Kokoro-82M is a natural on-device neural voice running via Apple MLX — private and offline once downloaded (~600 MB). Best paired with the Apple Intelligence backend, or when the local Gemma model isn't loaded, to leave memory headroom.")
            }

            Section {
                if isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: kokoro.downloadProgress)
                        Text("Downloading… \(Int(kokoro.downloadProgress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        download()
                    } label: {
                        Label(kokoro.isModelReady ? "Re-download Model" : "Download Model", systemImage: "arrow.down.circle")
                    }
                }
                if let downloadError {
                    Text(downloadError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Keep the app open during download and use Wi-Fi. Voices download automatically the first time you use them.")
            }

            if modelSizeBytes > 0 && !isDownloading {
                Section {
                    Button(role: .destructive) {
                        kokoro.deleteModel()
                        modelSizeBytes = 0
                    } label: {
                        HStack {
                            Label("Delete Kokoro Model", systemImage: "trash")
                            Spacer()
                            Text(sizeText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Removes the model and downloaded voices to free storage. You can re-download anytime.")
                }
            }
        }
        .navigationTitle("Kokoro Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { modelSizeBytes = KokoroTTSService.downloadedSizeBytes() }
    }

    private func download() {
        downloadError = nil
        isDownloading = true
        Task {
            do {
                try await kokoro.downloadModel { _ in }
                modelSizeBytes = KokoroTTSService.downloadedSizeBytes()
            } catch {
                downloadError = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

#Preview {
    NavigationStack { KokoroSettingsView() }
}
