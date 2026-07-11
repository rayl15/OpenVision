// OpenVision - SwirlOrb.swift
// The assistant's identity: a glowing emerald torus of woven light with lifelike state motion.
//
// Structure: a ROSETTE — thin bright ellipses rotated evenly around the center into a woven torus
// with a dim glowing hole (per the reference). Motion is scale-based BREATHING + glow, NOT fast
// spinning (fast rotation of the dense rosette strobes and reads cheap). Rotation is slow and
// constant. State changes how it breathes/glows, eased smoothly:
//   • idle      — gentle slow breathe
//   • listening — tightens (contracts) + brightens, nearly still (focused)
//   • thinking  — steadier, deeper breathing pulse (working)
//   • speaking  — expands + brightest, livelier breathe
// (Standard voice-orb state language — Siri / ChatGPT-voice style.)

import SwiftUI

struct SwirlOrb: View {
    enum Mode: Equatable { case idle, listening, thinking, speaking }

    var mode: Mode = .idle
    var size: CGFloat = 250

    private let loopCount = 9
    /// One breathing frequency for all states — varying it would jump the sine's phase. States
    /// differ by amplitude / baseline scale / glow instead.
    private let breatheFreq: Double = 1.35

    // Smoothly-eased, state-driven outer modifiers.
    @State private var baseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let rot = t * 0.06                                      // constant, slow — calm
            let breathe = 1.0 + sin(t * breatheFreq) * breatheAmp   // continuous gentle breathe

            core(rotation: rot)
                .scaleEffect(breathe)
        }
        .scaleEffect(baseScale)                                     // state contract / expand
        .overlay(stateGlow)                                         // state brightening halo
        .onChange(of: mode) { _, newMode in apply(newMode) }
        .onAppear { apply(mode) }
    }

    // MARK: - Motion params (per state)

    private var breatheAmp: Double {
        switch mode {
        case .idle:      return 0.020
        case .listening: return 0.008   // nearly still — focused
        case .thinking:  return 0.040   // deeper pulse — working
        case .speaking:  return 0.055   // lively
        }
    }

    private func apply(_ m: Mode) {
        withAnimation(.easeInOut(duration: 0.55)) {
            switch m {
            case .idle:      baseScale = 1.00; glowOpacity = 0.00
            case .listening: baseScale = 0.92; glowOpacity = 0.35   // tighten + brighten
            case .thinking:  baseScale = 1.00; glowOpacity = 0.28
            case .speaking:  baseScale = 1.06; glowOpacity = 0.50   // expand + brightest
            }
        }
    }

    /// Additive green halo whose strength eases with state (keeps the emerald — no white wash).
    private var stateGlow: some View {
        Circle()
            .fill(RadialGradient(colors: [Theme.glow, .clear], center: .center, startRadius: 0, endRadius: size * 0.55))
            .frame(width: size * 1.15, height: size * 1.15)
            .blur(radius: 24)
            .opacity(glowOpacity)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    // MARK: - The orb itself

    @ViewBuilder
    private func core(rotation: Double) -> some View {
        ZStack {
            // Ambient bloom — fades fully to clear inside the frame (no hard box edge).
            Circle()
                .fill(RadialGradient(colors: [Theme.glow.opacity(0.42), Theme.accent.opacity(0.12), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.60))
                .frame(width: size * 1.2, height: size * 1.2)
                .blur(radius: 30)

            // Dim green fill for the torus hole (center is darker, not a bright core).
            Circle()
                .fill(RadialGradient(colors: [Theme.accent.opacity(0.22), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.24))
                .frame(width: size * 0.55, height: size * 0.55)
                .blur(radius: 16)

            rosette(spin: rotation).blur(radius: 9).opacity(0.85)   // glow pass
            rosette(spin: rotation)                                  // crisp pass
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }

    @ViewBuilder
    private func rosette(spin: Double) -> some View {
        ZStack {
            ForEach(0..<loopCount, id: \.self) { i in
                let angle = Double(i) / Double(loopCount) * 2 * .pi + spin
                Ellipse()
                    .stroke(Theme.loopGradient, style: StrokeStyle(lineWidth: size * 0.012, lineCap: .round))
                    .frame(width: size * 0.88, height: size * 0.50)
                    .rotationEffect(.radians(angle))
            }
        }
    }
}

/// Compact line-art orb mark for the tab bar (three interlocked loops, like the app icon).
struct SwirlMark: View {
    var size: CGFloat = 28
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Ellipse()
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                    .frame(width: size * 0.9, height: size * 0.52)
                    .rotationEffect(.degrees(Double(i) * 60))
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    ZStack {
        Theme.bg.ignoresSafeArea()
        SwirlOrb(mode: .speaking)
    }
    .preferredColorScheme(.dark)
}
