// OpenVision - HapticFeedback.swift
// Haptic feedback utility for tactile user feedback

import UIKit

/// Utility for triggering haptic feedback
enum HapticFeedback {

    // MARK: - Impact Feedback

    /// Light impact feedback (subtle tap)
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Medium impact feedback (standard tap)
    static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Heavy impact feedback (strong tap)
    static func heavy() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Soft impact feedback (gentle)
    static func soft() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Rigid impact feedback (crisp)
    static func rigid() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred()
    }

    // MARK: - Notification Feedback

    /// Success feedback (positive action completed)
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    /// Warning feedback (action needs attention)
    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Error feedback (action failed)
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    // MARK: - Selection Feedback

    /// Selection changed feedback (picker, segment change)
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    // MARK: - Common Patterns

    /// Button tap feedback
    static func buttonTap() {
        light()
    }

    /// Toggle switch feedback
    static func toggle() {
        medium()
    }

    /// Wake word detected feedback
    static func wakeWordDetected() {
        // Double tap pattern for wake word
        medium()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            light()
        }
    }

    /// Session started feedback
    static func sessionStarted() {
        success()
    }

    /// Session ended feedback
    static func sessionEnded() {
        soft()
    }

    /// Photo captured feedback
    static func photoCaptured() {
        rigid()
    }

    /// Error occurred feedback
    static func errorOccurred() {
        error()
    }

    /// Connection state change feedback
    static func connectionChanged(connected: Bool) {
        if connected {
            success()
        } else {
            warning()
        }
    }
}

// MARK: - SwiftUI View Modifier

import SwiftUI

/// View modifier for adding haptic feedback to tap gestures
struct HapticTapModifier: ViewModifier {
    let style: HapticStyle
    let action: () -> Void

    enum HapticStyle {
        case light
        case medium
        case heavy
        case success
        case warning
        case error
        case selection
    }

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                triggerHaptic()
                action()
            }
    }

    private func triggerHaptic() {
        switch style {
        case .light: HapticFeedback.light()
        case .medium: HapticFeedback.medium()
        case .heavy: HapticFeedback.heavy()
        case .success: HapticFeedback.success()
        case .warning: HapticFeedback.warning()
        case .error: HapticFeedback.error()
        case .selection: HapticFeedback.selection()
        }
    }
}

extension View {
    /// Add haptic feedback to tap gesture
    func hapticTap(
        style: HapticTapModifier.HapticStyle = .light,
        action: @escaping () -> Void
    ) -> some View {
        modifier(HapticTapModifier(style: style, action: action))
    }
}
