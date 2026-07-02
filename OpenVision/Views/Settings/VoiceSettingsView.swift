// OpenVision - VoiceSettingsView.swift
// Voice control settings: wake word, conversation timeout

import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - Computed Properties

    private var selectedVoiceName: String {
        guard let identifier = settingsManager.settings.selectedVoiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
            return "System Default"
        }
        return voice.name
    }

    // MARK: - Body

    var body: some View {
        Form {
            // Wake Word Section
            Section {
                Toggle(isOn: $settingsManager.settings.wakeWordEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Wake Word")
                        Text("Only listen after wake phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if settingsManager.settings.wakeWordEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wake Phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Ok Vision", text: $settingsManager.settings.wakeWord)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("Wake Word")
            } footer: {
                if settingsManager.settings.wakeWordEnabled {
                    Text("Say \"\(settingsManager.settings.wakeWord)\" to activate the assistant. This protects your privacy by only listening after the wake phrase.")
                } else {
                    Text("Wake word is disabled. The app will always be listening when active (Gemini Live mode behavior).")
                }
            }

            // Conversation Section
            Section {
                Picker("Auto-End Timeout", selection: $settingsManager.settings.conversationTimeout) {
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("Never").tag(TimeInterval(0))
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("Automatically end the conversation after this period of silence.")
            }

            // TTS Voice Section
            Section {
                Picker("Speech Engine", selection: $settingsManager.settings.ttsEngine) {
                    ForEach(TTSEngineType.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                if settingsManager.settings.ttsEngine == .appleSystem {
                    NavigationLink {
                        VoiceSelectionView()
                    } label: {
                        HStack {
                            Text("Apple Voice")
                            Spacer()
                            Text(selectedVoiceName).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Picker("Kokoro Voice", selection: $settingsManager.settings.kokoroVoice) {
                        ForEach(KokoroTTSService.voices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                    NavigationLink {
                        KokoroSettingsView()
                    } label: {
                        HStack {
                            Label("Kokoro Model", systemImage: "waveform")
                            Spacer()
                            Text(KokoroTTSService.shared.isModelReady ? "Ready" : "Download")
                                .font(.caption)
                                .foregroundColor(KokoroTTSService.shared.isModelReady ? .green : .orange)
                        }
                    }
                }
            } header: {
                Text("Output Voice")
            } footer: {
                if settingsManager.settings.ttsEngine == .kokoro {
                    Text("Kokoro is a natural, on-device neural voice — private and offline. Download its model (~600 MB) under Kokoro Model, then it runs entirely on-device.")
                } else {
                    Text("Apple's built-in system voice. For higher quality, download a Premium/Enhanced voice in iOS Settings → Accessibility → Spoken Content.")
                }
            }

            // Feedback Section
            Section {
                Toggle(isOn: $settingsManager.settings.playActivationSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activation Sound")
                        Text("Play chime on wake word")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Feedback")
            }

            // Info Section
            Section {
                HStack {
                    Text("Supported Phrases")
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(samplePhrases, id: \.self) { phrase in
                        HStack {
                            Image(systemName: "quote.bubble")
                                .foregroundColor(.secondary)
                            Text(phrase)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Examples")
            } footer: {
                Text("The wake word detection is flexible and will recognize variations like \"OK Vision\" or \"Okay Vision\".")
            }
        }
        .navigationTitle("Voice Control")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sample Phrases

    private var samplePhrases: [String] {
        let wake = settingsManager.settings.wakeWord
        return [
            "\(wake), what's the weather?",
            "\(wake), take a photo",
            "\(wake), remind me to...",
            "\(wake), search for..."
        ]
    }
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
