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

    /// A "Voice" row that opens a voice list, styled like the Apple Voice row.
    private func voiceRow<Destination: View>(_ title: String, value: String,
                                             @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundColor(.secondary)
            }
        }
    }

    /// Shortcut to the credential a cloud voice uses, with its status.
    private func accountRow<Destination: View>(_ title: String, icon: String, connected: Bool,
                                               @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(connected ? "Connected" : "Set Up")
                    .font(.caption)
                    .foregroundColor(connected ? .green : .orange)
            }
        }
    }

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

            // Microphone Section
            Section {
                Toggle(isOn: $settingsManager.settings.preferGlassesMic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Glasses Mic")
                        Text("Listen through the glasses when worn")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("When on, voice input uses the glasses' Bluetooth microphone for true hands-free use, and falls back to the phone mic automatically when the glasses aren't the audio device. Uses more battery. Turn off to always use the phone mic.")
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

                switch settingsManager.settings.ttsEngine {
                case .appleSystem:
                    NavigationLink {
                        VoiceSelectionView()
                    } label: {
                        HStack {
                            Text("Apple Voice")
                            Spacer()
                            Text(selectedVoiceName).foregroundColor(.secondary)
                        }
                    }
                case .kokoro:
                    voiceRow("Kokoro Voice", value: settingsManager.settings.kokoroVoice) {
                        NeuralVoiceListView(
                            engine: .kokoro,
                            title: "Kokoro Voice",
                            selection: $settingsManager.settings.kokoroVoice,
                            voices: KokoroTTSService.voices.map { CloudVoice(id: $0, name: $0, gender: "") },
                            preview: { await KokoroTTSService.shared.speak(NeuralVoiceListView.sampleText, voice: $0) }
                        )
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
                case .grok:
                    voiceRow("Grok Voice", value: settingsManager.settings.grokVoice.capitalized) {
                        NeuralVoiceListView(
                            engine: .grok,
                            title: "Grok Voice",
                            selection: $settingsManager.settings.grokVoice,
                            loadVoices: { try await CloudTTSService.fetchGrokVoices() },
                            preview: { await CloudTTSService.grok.speak(NeuralVoiceListView.sampleText, voice: $0) }
                        )
                    }
                    accountRow("Grok Account", icon: "bolt", connected: settingsManager.settings.isGrokConfigured) {
                        GrokSettingsView()
                    }
                case .openAI:
                    voiceRow("OpenAI Voice", value: settingsManager.settings.openAITTSVoice.capitalized) {
                        NeuralVoiceListView(
                            engine: .openAI,
                            title: "OpenAI Voice",
                            selection: $settingsManager.settings.openAITTSVoice,
                            voices: CloudTTSService.openAIVoices,
                            preview: { await CloudTTSService.openAI.speak(NeuralVoiceListView.sampleText, voice: $0) }
                        )
                    }
                    accountRow("OpenAI API Key", icon: "key", connected: settingsManager.settings.isOpenAIAPIAvailable) {
                        OpenAISettingsView()
                    }
                }
            } header: {
                Text("Output Voice")
            } footer: {
                switch settingsManager.settings.ttsEngine {
                case .kokoro:
                    Text("Kokoro is a natural, on-device neural voice — private and offline. Download its model (~600 MB) under Kokoro Model, then it runs entirely on-device.")
                case .grok:
                    Text("Grok is xAI's natural cloud voice. It uses your Grok sign-in (SuperGrok or API key), follows the language of each reply, and needs an internet connection. Replies are sent to xAI to be spoken.")
                case .openAI:
                    Text("OpenAI's natural cloud voice (\(CloudTTSService.openAITTSModel)). It needs an OpenAI API key with credits — a ChatGPT subscription doesn't cover speech. Replies are sent to OpenAI to be spoken.")
                case .appleSystem:
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
