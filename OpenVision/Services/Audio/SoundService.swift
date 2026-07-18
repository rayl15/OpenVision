// OpenVision - SoundService.swift
// Service for playing UI sound effects.
//
// The wake-word "I'm listening" chime plays via AVAudioPlayer on the app's active audio session,
// so it follows the current route — crucially the glasses' Bluetooth (HFP) speaker when they're
// connected. System sounds (AudioServicesPlaySystemSound) always go to the phone speaker, so with
// the phone in a pocket you'd hear nothing on the glasses — which is why the chime was silent.

import AudioToolbox
import AVFoundation
import Foundation

/// Service for playing UI sound effects
@MainActor
final class SoundService: ObservableObject {
    // MARK: - Singleton

    static let shared = SoundService()

    // MARK: - Players

    /// AVAudioPlayer so the wake-word chime routes to the active output (the glasses when connected).
    private var wakeWordPlayer: AVAudioPlayer?

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

        // Wake-word "listening" chime — via AVAudioPlayer so it follows the active route (glasses).
        // Falls back to the older ding file if the new asset isn't present.
        let wakeURL = Bundle.main.url(forResource: "wake_activation", withExtension: "mp3")
            ?? Bundle.main.url(forResource: "wake_word_ding", withExtension: "mp3")
        if let wakeURL {
            wakeWordPlayer = try? AVAudioPlayer(contentsOf: wakeURL)
            wakeWordPlayer?.prepareToPlay()
        }

        // Thinking loop sound (stays a system sound — ambient, phone-side is fine)
        if let url = Bundle.main.url(forResource: "thinking_loop", withExtension: "mp3") {
            AudioServicesCreateSystemSoundID(url as CFURL, &thinkingSoundID)
        }
    }

    // MARK: - Wake Word Sound

    func playWakeWordSound() {
        guard soundEnabled else { return }
        ensureSoundsReady()

        // Play on the app's audio session so it routes to the glasses (HFP) when connected.
        // The wake-word recognizer keeps a .playAndRecord session active, so the current output
        // route is already correct — just restart the player from the top and play.
        if let player = wakeWordPlayer {
            player.currentTime = 0
            player.play()
        } else if wakeWordSoundID != 0 {
            AudioServicesPlaySystemSound(wakeWordSoundID)   // fallback
        }
    }

    /// Play an alert chime for timers/alarms — via the app's active AVAudioPlayer session, so it's
    /// audible even in silent mode and routes to the glasses. Notification sounds get suppressed while
    /// our audio session is active, so we play our own. Unconditional (a timer must be heard).
    func playAlert() {
        ensureSoundsReady()
        if let player = wakeWordPlayer {
            player.currentTime = 0
            player.play()
        } else if wakeWordSoundID != 0 {
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
