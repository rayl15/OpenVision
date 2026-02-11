// OpenVision - SoundService.swift
// Service for playing UI sound effects using System Sounds (no audio session interference)

import AudioToolbox
import Foundation

/// Service for playing UI sound effects
@MainActor
final class SoundService: ObservableObject {
    // MARK: - Singleton

    static let shared = SoundService()

    // MARK: - System Sound IDs

    private var wakeWordSoundID: SystemSoundID = 0
    private var thinkingSoundID: SystemSoundID = 0

    // MARK: - State

    @Published var isPlayingThinkingSound: Bool = false
    private var thinkingTimer: Timer?
    private var hasSetupSounds = false

    // MARK: - Settings

    private var soundEnabled: Bool {
        SettingsManager.shared.settings.playActivationSound
    }

    // MARK: - Initialization

    private init() {
        // Don't setup sounds here - do it lazily
    }

    deinit {
        if wakeWordSoundID != 0 {
            AudioServicesDisposeSystemSoundID(wakeWordSoundID)
        }
        if thinkingSoundID != 0 {
            AudioServicesDisposeSystemSoundID(thinkingSoundID)
        }
    }

    // MARK: - Lazy Setup

    private func ensureSoundsReady() {
        guard !hasSetupSounds else { return }
        hasSetupSounds = true

        // Wake word ding sound
        if let url = Bundle.main.url(forResource: "wake_word_ding", withExtension: "mp3") {
            AudioServicesCreateSystemSoundID(url as CFURL, &wakeWordSoundID)
        }

        // Thinking loop sound
        if let url = Bundle.main.url(forResource: "thinking_loop", withExtension: "mp3") {
            AudioServicesCreateSystemSoundID(url as CFURL, &thinkingSoundID)
        }
    }

    // MARK: - Wake Word Sound

    func playWakeWordSound() {
        guard soundEnabled else { return }
        ensureSoundsReady()

        if wakeWordSoundID != 0 {
            AudioServicesPlaySystemSound(wakeWordSoundID)
        }
    }

    // MARK: - Thinking Sound

    func startThinkingSound() {
        guard soundEnabled else { return }
        guard !isPlayingThinkingSound else { return }

        ensureSoundsReady()
        isPlayingThinkingSound = true

        // Play immediately
        playThinkingSoundOnce()

        // Set up timer to repeat every 3 seconds
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.playThinkingSoundOnce()
            }
        }
    }

    func stopThinkingSound() {
        isPlayingThinkingSound = false
        thinkingTimer?.invalidate()
        thinkingTimer = nil
    }

    private func playThinkingSoundOnce() {
        guard isPlayingThinkingSound else { return }
        if thinkingSoundID != 0 {
            AudioServicesPlaySystemSound(thinkingSoundID)
        }
    }
}
