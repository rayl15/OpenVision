// OpenVision - Theme.swift
// App-wide visual theme: emerald-on-black assistant aesthetic.
//
// Palette + gradients live here so surfaces stay consistent and re-coloring the brand is a
// one-file change. Modeled on the reference design: near-black backgrounds with a vivid emerald
// glow as the single signature accent.

import SwiftUI

enum Theme {
    // MARK: - Core accent (emerald)

    /// Signature emerald — buttons, active states, the orb.
    static let accent = Color(red: 0.16, green: 0.85, blue: 0.47)        // ~#29D978
    /// Brighter tint for highlights / glow cores.
    static let accentBright = Color(red: 0.45, green: 0.96, blue: 0.58)  // ~#73F594
    /// Deeper emerald for gradient shadows.
    static let accentDeep = Color(red: 0.04, green: 0.55, blue: 0.30)    // ~#0A8C4D
    /// Luminous green used for glows.
    static let glow = Color(red: 0.22, green: 0.95, blue: 0.52)

    // MARK: - Backgrounds

    static let bg = Color(red: 0.02, green: 0.03, blue: 0.025)           // near-black, faint green
    static let bgElevated = Color(red: 0.07, green: 0.09, blue: 0.075)   // cards / pills
    static let bgElevatedStroke = Color.white.opacity(0.08)

    // MARK: - Text

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    /// Light-green heading tint (the "What can I do…" look).
    static let heading = Color(red: 0.62, green: 0.98, blue: 0.66)

    // MARK: - Gradients

    /// Primary CTA / active pill fill (top-lit emerald).
    static var buttonGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.34, green: 0.96, blue: 0.58), Color(red: 0.10, green: 0.78, blue: 0.42)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Stroke gradient for the swirling orb rings.
    static var ringGradient: AngularGradient {
        AngularGradient(
            colors: [accentBright, accent, accentDeep, accent, accentBright],
            center: .center
        )
    }

    /// Ambient radial glow used behind the orb / at screen top.
    static func glowGradient(_ opacity: Double = 0.9) -> RadialGradient {
        RadialGradient(
            colors: [glow.opacity(opacity), accent.opacity(opacity * 0.35), .clear],
            center: .center, startRadius: 0, endRadius: 220
        )
    }

    // MARK: - Surfaces

    /// Frosted card fill.
    static let glass = Color.white.opacity(0.05)
}
