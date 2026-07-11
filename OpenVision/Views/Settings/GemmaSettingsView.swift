// OpenVision - GemmaSettingsView.swift
// Download & manage the on-device Gemma 4 model for the Local backend.

import SwiftUI

struct GemmaSettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var gemma = GemmaLocalService.shared

    @State private var selectedModel: GemmaLocalModel = .e2b
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var modelSizeBytes: Int64 = 0

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: modelSizeBytes, countStyle: .file)
    }

    var body: some View {
        Form {
            Section {
                ForEach(GemmaLocalModel.allCases) { model in
                    Button {
                        selectedModel = model
                        refreshSize()
                        // If this model is already on disk, make it the ACTIVE local model right
                        // away. The setting used to persist only after a fresh download, so
                        // switching between already-downloaded models never took effect — the
                        // home screen (and the backend) stayed on the previous model.
                        if GemmaLocalService.downloadedSizeBytes(for: model.modelId) > 0 {
                            settingsManager.settings.localGemmaModelId = model.modelId
                            settingsManager.settings.localGemmaModelReady = true
                            settingsManager.saveNow()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .foregroundStyle(.primary)
                                Text(model.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedModel == model {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Runs entirely on-device via Apple MLX. Requires iOS 18+ and a physical device — no API key, no cloud, works offline.")
            }

            Section {
                if isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: gemma.downloadProgress)
                        Text("Downloading… \(Int(gemma.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        download()
                    } label: {
                        Label(
                            settingsManager.settings.isLocalGemmaConfigured ? "Re-download Model" : "Download Model",
                            systemImage: "arrow.down.circle"
                        )
                    }
                }

                if let downloadError {
                    Text(downloadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Download")
            } footer: {
                if settingsManager.settings.isLocalGemmaConfigured {
                    Label("Model ready — select “Local (MLX)” as your backend.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("The first download is several GB — keep the app open and use Wi-Fi.")
                }
            }

            // Free up storage whenever there's model data on disk — even if the app's "ready" flag
            // is off (e.g. orphaned files left by a previous incomplete delete).
            if modelSizeBytes > 0 && !isDownloading {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Label(isDeleting ? "Deleting…" : "Delete Downloaded Model", systemImage: "trash")
                            Spacer()
                            Text(sizeText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text("Removes \(sizeText) of model data from your phone. You can download it again anytime.")
                }
            }
        }
        .navigationTitle("Local Models")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedModel = GemmaLocalModel.from(modelId: settingsManager.settings.localGemmaModelId)
            refreshSize()
        }
        .alert("Delete downloaded model?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(modelSizeBytes > 0
                 ? "This frees up \(sizeText) of storage. You can re-download it anytime."
                 : "You can re-download it anytime.")
        }
    }

    private func refreshSize() {
        modelSizeBytes = GemmaLocalService.downloadedSizeBytes(for: selectedModel.modelId)
    }

    private func deleteModel() {
        isDeleting = true
        Task {
            let ok = await GemmaLocalService.shared.deleteDownloadedModel(selectedModel.modelId)
            if ok {
                settingsManager.settings.localGemmaModelReady = false
                settingsManager.saveNow()
                modelSizeBytes = 0
            }
            isDeleting = false
        }
    }

    private func download() {
        downloadError = nil
        isDownloading = true
        Task {
            do {
                try await gemma.download(selectedModel) { _ in }
                settingsManager.settings.localGemmaModelId = selectedModel.modelId
                settingsManager.settings.localGemmaModelReady = true
            } catch {
                downloadError = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

#Preview {
    NavigationStack { GemmaSettingsView() }
}
