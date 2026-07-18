// OpenVision - VoiceAgentView.swift
// Beautiful main voice conversation UI with glassmorphism design.
//
// MVVM: this view only renders state and forwards interactions — every piece of orchestration
// (session lifecycle, command routing, live video, TTS streaming) lives in VoiceAgentViewModel.

import SwiftUI

struct VoiceAgentView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - ViewModel

    @StateObject private var viewModel = VoiceAgentViewModel()

    // MARK: - Observed services
    // Only the services whose @Published state the body reacts to directly. They are the same
    // singletons the ViewModel drives — observed here purely so onChange fires.

    @StateObject private var voiceCommandService = VoiceCommandService.shared
    @StateObject private var ttsService = TTSService.shared
    @StateObject private var kokoroTTS = KokoroTTSService.shared

    // MARK: - Body

    var body: some View {
        ZStack {
            // Beautiful animated background
            AnimatedBackground()

            // Particle effects
            ParticleEffect(particleCount: 30)
                .opacity(0.5)

            // Main content — the orb stays vertically centered and STABLE. The transcript is a
            // separate overlay (below) so it can never push the orb around.
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                Spacer()
                centerContent
                Spacer()
            }

            // Transcript floats over the bottom; growing text stays inside its own card and doesn't
            // move the orb.
            if settingsManager.settings.showTranscripts
                && (!viewModel.userTranscript.isEmpty || !viewModel.aiTranscript.isEmpty || viewModel.agentState == .thinking) {
                VStack {
                    Spacer()
                    transcriptArea
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Error overlay
            if let error = viewModel.errorMessage {
                errorOverlay(error)
            }
        }
        // Animate the state text and the transcript's appear/disappear only — NOT every streamed
        // token (the old .spring on userTranscript/aiTranscript sprang the whole view and jostled
        // the orb on every word).
        .animation(.easeInOut(duration: 0.3), value: viewModel.agentState)
        .animation(.easeInOut(duration: 0.35), value: viewModel.userTranscript.isEmpty)
        .animation(.easeInOut(duration: 0.35), value: viewModel.aiTranscript.isEmpty)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .task {
            await viewModel.requestSpeechAuthorization()
        }
        // Observe TTS state changes
        .onChange(of: ttsService.isSpeaking) { isSpeaking in
            viewModel.ttsSpeakingChanged(isSpeaking)
        }
        .onChange(of: kokoroTTS.isSpeaking) { speaking in
            viewModel.kokoroSpeakingChanged(speaking)
        }
        // Control thinking sound based on agent state
        .onChange(of: viewModel.agentState) { newState in
            viewModel.agentStateChanged(newState)
        }
        // Observe VoiceCommandService state changes
        .onChange(of: voiceCommandService.state) { newState in
            viewModel.voiceStateChanged(newState)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // AI Backend status (or Live Video indicator)
            if viewModel.isLiveVideoMode {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(.red.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.5)
                        )

                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundColor(.white)

                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.red.opacity(0.8))
                )
            } else {
                StatusPill(
                    status: settingsManager.settings.backendDisplayName,
                    color: viewModel.agentState == .idle ? .gray : .green,
                    isConnected: viewModel.agentState != .idle && viewModel.agentState != .connecting
                )
            }

            Spacer()

            // Glasses status
            HStack(spacing: 8) {
                Image(systemName: "eyeglasses")
                    .foregroundColor(glassesManager.isRegistered ? .green : .gray)

                if glassesManager.isStreaming {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Center Content

    /// Map the agent state to the orb's visual mode.
    private var orbMode: SwirlOrb.Mode {
        switch viewModel.agentState {
        case .listening: return .listening
        case .speaking: return .speaking
        case .thinking, .toolRunning, .connecting: return .thinking
        case .idle, .liveVideo: return .idle
        }
    }

    private var centerContent: some View {
        VStack(spacing: 28) {
            // Heading / status prompt
            Group {
                if viewModel.agentState == .liveVideo {
                    VStack(spacing: 6) {
                        Text(settingsManager.settings.backendDisplayName)
                            .font(.headline)
                            .foregroundColor(Theme.heading)
                        Text("Say \"stop video\" to exit")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                } else if viewModel.agentState == .idle && settingsManager.settings.wakeWordEnabled {
                    VStack(spacing: 8) {
                        Text("What can I see?")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.heading)
                        if viewModel.isVoiceReady {
                            Text("Say \"\(settingsManager.settings.wakeWord)\" or tap the orb")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().tint(Theme.accent).scaleEffect(0.8)
                                Text("Initializing voice…")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .transition(.opacity)

            // The assistant identity: swirling emerald orb (tap to start/stop a session)
            SwirlOrb(mode: orbMode, size: 250)
                .onTapGesture { viewModel.toggleSession() }

            // Status text
            Text(viewModel.agentState.displayText)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(Theme.textPrimary)

            // Tool status
            if let tool = viewModel.currentToolName, viewModel.agentState == .toolRunning {
                ToolStatusView(toolName: tool, isRunning: true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Transcript Area

    // Bubbles float directly over the background (no outer card box — the old GlassCard wrapper
    // was a mostly-empty gray slab).
    private var transcriptArea: some View {
        TranscriptView(
            userText: viewModel.userTranscript,
            aiText: viewModel.aiTranscript,
            isAIStreaming: viewModel.agentState == .speaking
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Button {
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.red.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            .padding(.bottom, 150)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    VoiceAgentView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .preferredColorScheme(.dark)
}
