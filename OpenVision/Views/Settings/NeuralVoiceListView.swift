// OpenVision - NeuralVoiceListView.swift
// Voice picker for the neural speech engines (Kokoro, Grok, OpenAI): tap a row to choose it, tap
// its ▶ to hear a sample first — the same pattern as the Apple voice list (VoiceSelectionView).

import SwiftUI

struct NeuralVoiceListView: View {
    /// The engine whose voices these are — decides whether samples can play and what's missing.
    let engine: TTSEngineType
    let title: String
    @Binding var selection: String
    /// Voices known up front (Kokoro, OpenAI); Grok's come from `loadVoices`.
    var voices: [CloudVoice] = []
    var loadVoices: (() async throws -> [CloudVoice])? = nil
    /// Speak the sample in a given voice id.
    let preview: (String) async -> Void

    @State private var loaded: [CloudVoice] = []
    @State private var loadError: String?
    @State private var previewingId: String?

    // Observed so a row's ▶ flips back when its sample finishes.
    @ObservedObject private var kokoroTTS = KokoroTTSService.shared
    @ObservedObject private var grokTTS = CloudTTSService.grok
    @ObservedObject private var openAITTS = CloudTTSService.openAI

    static let sampleText = "Hello! This is how I sound. I'm your AI assistant."

    var body: some View {
        List {
            Section {
                ForEach(choices) { voice in row(voice) }
            } footer: {
                if let message = failure ?? loadError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                } else if !canPreview {
                    Text(setupHint)
                }
            }
        }
        .navigationTitle(title)
        .task {
            guard let loadVoices, loaded.isEmpty, canPreview else { return }
            do {
                loaded = try await loadVoices()
                loadError = nil
            } catch {
                loadError = "Couldn't load the voice list: \(error.localizedDescription)"
            }
        }
        .onChange(of: isAnySpeaking) { _, speaking in
            if !speaking { previewingId = nil }
        }
        .onDisappear {
            if previewingId != nil { NeuralSpeech.stopAll() }
        }
    }

    /// Whether this engine can speak right now (model downloaded / credential configured).
    private var canPreview: Bool {
        switch engine {
        case .kokoro: return kokoroTTS.isModelReady
        case .grok: return grokTTS.isReady
        case .openAI: return openAITTS.isReady
        case .appleSystem: return true
        }
    }

    private var setupHint: String {
        switch engine {
        case .kokoro: return "Download the Kokoro model to hear samples."
        case .grok: return "Sign in to SuperGrok or add an xAI API key in Grok Settings to hear samples."
        case .openAI: return "Add an OpenAI API key (with credits) in OpenAI Settings to hear samples. A ChatGPT subscription doesn't cover speech."
        case .appleSystem: return ""
        }
    }

    /// The last cloud synthesis error for this engine, e.g. an invalid key or no credits.
    private var failure: String? {
        switch engine {
        case .grok: return grokTTS.lastFailure
        case .openAI: return openAITTS.lastFailure
        case .kokoro, .appleSystem: return nil
        }
    }

    private var isAnySpeaking: Bool {
        kokoroTTS.isSpeaking || grokTTS.isSpeaking || openAITTS.isSpeaking
    }

    /// The available voices, plus the saved one if the list doesn't have it (yet).
    private var choices: [CloudVoice] {
        let all = voices + loaded
        if all.contains(where: { $0.id == selection }) { return all }
        return [CloudVoice(id: selection, name: selection.capitalized, gender: "")] + all
    }

    private func row(_ voice: CloudVoice) -> some View {
        Button {
            selection = voice.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(voice.name)
                        .foregroundColor(.primary)
                    if !voice.gender.isEmpty {
                        Text(voice.gender.capitalized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    togglePreview(voice.id)
                } label: {
                    Image(systemName: previewingId == voice.id ? "stop.circle" : "play.circle")
                        .foregroundColor(Theme.accent)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .disabled(!canPreview)
                .opacity(canPreview ? 1 : 0.35)
                .accessibilityLabel(previewingId == voice.id ? "Stop sample" : "Play sample of \(voice.name)")

                if selection == voice.id {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.accent)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == voice.id ? .isSelected : [])
    }

    private func togglePreview(_ id: String) {
        if previewingId == id {
            NeuralSpeech.stopAll()
            previewingId = nil
            return
        }
        NeuralSpeech.stopAll()
        previewingId = id
        Task { await preview(id) }
    }
}
