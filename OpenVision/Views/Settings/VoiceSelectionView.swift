// OpenVision - VoiceSelectionView.swift
// Voice picker for TTS output

import SwiftUI
import AVFoundation

struct VoiceSelectionView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - State

    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var isTestingVoice: Bool = false
    @State private var testingVoiceId: String? = nil

    // MARK: - Body

    var body: some View {
        List {
            // System Default Option
            Section {
                voiceRow(
                    name: "System Default",
                    quality: nil,
                    identifier: nil,
                    isSelected: settingsManager.settings.selectedVoiceIdentifier == nil
                )
            } footer: {
                Text("Uses the default voice from iOS Settings → Accessibility → Spoken Content")
            }

            // Premium Voices
            let premiumVoices = voices.filter { $0.quality == .premium }
            if !premiumVoices.isEmpty {
                Section {
                    ForEach(premiumVoices, id: \.identifier) { voice in
                        voiceRow(
                            name: voice.name,
                            quality: voice.quality,
                            identifier: voice.identifier,
                            isSelected: settingsManager.settings.selectedVoiceIdentifier == voice.identifier
                        )
                    }
                } header: {
                    Text("Premium Voices")
                } footer: {
                    Text("Highest quality, most natural sounding")
                }
            }

            // Enhanced Voices
            let enhancedVoices = voices.filter { $0.quality == .enhanced }
            if !enhancedVoices.isEmpty {
                Section {
                    ForEach(enhancedVoices, id: \.identifier) { voice in
                        voiceRow(
                            name: voice.name,
                            quality: voice.quality,
                            identifier: voice.identifier,
                            isSelected: settingsManager.settings.selectedVoiceIdentifier == voice.identifier
                        )
                    }
                } header: {
                    Text("Enhanced Voices")
                } footer: {
                    Text("Better quality than default")
                }
            }

            // Default Voices
            let defaultVoices = voices.filter { $0.quality == .default }
            if !defaultVoices.isEmpty {
                Section {
                    ForEach(defaultVoices, id: \.identifier) { voice in
                        voiceRow(
                            name: voice.name,
                            quality: voice.quality,
                            identifier: voice.identifier,
                            isSelected: settingsManager.settings.selectedVoiceIdentifier == voice.identifier
                        )
                    }
                } header: {
                    Text("Default Voices")
                }
            }

            // Download More Voices
            Section {
                Link(destination: URL(string: "App-prefs:ACCESSIBILITY&path=SPEECH")!) {
                    HStack {
                        Label("Download More Voices", systemImage: "square.and.arrow.down")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("Download premium and enhanced voices in iOS Settings → Accessibility → Spoken Content → Voices")
            }
        }
        .navigationTitle("TTS Voice")
        .onAppear {
            loadVoices()
        }
    }

    // MARK: - Voice Row

    @ViewBuilder
    private func voiceRow(name: String, quality: AVSpeechSynthesisVoiceQuality?, identifier: String?, isSelected: Bool) -> some View {
        Button {
            selectVoice(identifier: identifier)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .foregroundColor(.primary)

                    if let quality = quality {
                        Text(TTSService.qualityDisplayName(quality))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Test button
                Button {
                    testVoice(identifier: identifier)
                } label: {
                    if testingVoiceId == identifier {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.circle")
                            .foregroundColor(Theme.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isTestingVoice)

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.accent)
                        .fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func loadVoices() {
        voices = TTSService.availableVoices(for: "en")
    }

    private func selectVoice(identifier: String?) {
        settingsManager.settings.selectedVoiceIdentifier = identifier
    }

    private func testVoice(identifier: String?) {
        isTestingVoice = true
        testingVoiceId = identifier

        let utterance = AVSpeechUtterance(string: "Hello! This is how I sound. I'm your AI assistant.")

        if let identifier = identifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.speak(utterance)

        // Reset state after estimated speech duration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            isTestingVoice = false
            testingVoiceId = nil
        }
    }
}

#Preview {
    NavigationStack {
        VoiceSelectionView()
            .environmentObject(SettingsManager.shared)
    }
}
