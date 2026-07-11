// OpenVision - GemmaSettingsView.swift
// Download & manage the on-device MLX models for the Local backend.

import SwiftUI

struct GemmaSettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var gemma = GemmaLocalService.shared

    @State private var selectedModel: GemmaLocalModel = .e2b
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    /// On-disk bytes per model id (0 = not downloaded). Refreshed on appear and after changes.
    @State private var sizes: [String: Int64] = [:]

    private var selectedSizeBytes: Int64 { sizes[selectedModel.modelId] ?? 0 }
    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: selectedSizeBytes, countStyle: .file)
    }
    private var selectedIsDownloaded: Bool { isDownloaded(selectedModel) }
    private var activeModelId: String { settingsManager.settings.localGemmaModelId }

    /// "Downloaded" means most of the WEIGHTS are on disk. A snapshot holding only configs and
    /// tokenizer (~20 MB) used to pass a `> 0` check and made missing models look ready.
    private func isDownloaded(_ model: GemmaLocalModel) -> Bool {
        (sizes[model.modelId] ?? 0) >= model.expectedDownloadBytes / 2
    }

    var body: some View {
        Form {
            Section {
                ForEach(GemmaLocalModel.allCases) { model in
                    Button {
                        select(model)
                    } label: {
                        modelRow(model)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Runs entirely on-device via Apple MLX. Requires iOS 18+ and a physical device — no API key, no cloud, works offline. Tap a downloaded model to make it active.")
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
                            selectedIsDownloaded ? "Re-download Model" : "Download \(selectedModel.displayName)",
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
                if selectedIsDownloaded {
                    Label("\(selectedModel.displayName) is ready.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("The first download is several GB — keep the app open and use Wi-Fi.")
                }
            }

            if selectedIsDownloaded && !isDownloading {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Label(isDeleting ? "Deleting…" : "Delete \(selectedModel.displayName)", systemImage: "trash")
                            Spacer()
                            Text(sizeText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text("Removes \(sizeText) of model data from your phone (only this model). You can download it again anytime.")
                }
            }
        }
        .navigationTitle("Local Models")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedModel = GemmaLocalModel.from(modelId: settingsManager.settings.localGemmaModelId)
            refreshSizes()
            Task.detached { GemmaLocalService.debugDumpHubCache() }
        }
        .alert("Delete \(selectedModel.displayName)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selectedSizeBytes > 0
                 ? "This frees up \(sizeText) of storage. You can re-download it anytime."
                 : "You can re-download it anytime.")
        }
    }

    @ViewBuilder
    private func modelRow(_ model: GemmaLocalModel) -> some View {
        let downloaded = isDownloaded(model)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .foregroundStyle(.primary)
                    if model.modelId == activeModelId {
                        Text("ACTIVE")
                            .font(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.2)))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if downloaded {
                    Text("Downloaded • \(ByteCountFormatter.string(fromByteCount: sizes[model.modelId] ?? 0, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if (sizes[model.modelId] ?? 0) > 0 {
                    Text("Incomplete — download again")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if selectedModel == model {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func select(_ model: GemmaLocalModel) {
        selectedModel = model
        // If this model is already on disk, make it the ACTIVE local model right away. The
        // setting used to persist only after a fresh download, so switching between
        // already-downloaded models never took effect — the home screen (and the backend)
        // stayed on the previous model.
        if isDownloaded(model) {
            settingsManager.settings.localGemmaModelId = model.modelId
            settingsManager.settings.localGemmaModelReady = true
            settingsManager.saveNow()
        }
    }

    /// Measure every model's on-disk size off the main thread (walks a multi-GB tree).
    private func refreshSizes() {
        Task.detached {
            var result: [String: Int64] = [:]
            for model in GemmaLocalModel.allCases {
                result[model.modelId] = GemmaLocalService.downloadedSizeBytes(for: model.modelId)
            }
            let sizes = result
            await MainActor.run { self.sizes = sizes }
        }
    }

    private func deleteModel() {
        isDeleting = true
        Task {
            let ok = await GemmaLocalService.shared.deleteDownloadedModel(selectedModel.modelId)
            if ok {
                // Only clear the "ready" flag when the ACTIVE model was deleted.
                if selectedModel.modelId == settingsManager.settings.localGemmaModelId {
                    settingsManager.settings.localGemmaModelReady = false
                    settingsManager.saveNow()
                }
                refreshSizes()
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
                settingsManager.saveNow()
                refreshSizes()
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
