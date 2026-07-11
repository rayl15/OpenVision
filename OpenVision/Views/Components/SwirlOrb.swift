// OpenVision - SwirlOrb.swift
// The assistant's identity: a glowing emerald torus of woven light.
//
// The reference orb is a ROSETTE — many thin bright ellipses rotated evenly around the center,
// overlapping into a woven ring/torus with a dim glowing hole (not a few thick tilted rings and
// not a bright core). The whole rosette spins slowly; `isActive` speeds it up, `intensity` (0…1
// audio) makes it breathe. Glow pass + crisp pass = luminous but defined. No drawingGroup (that
// clipped the blur into a visible box).

import SwiftUI

struct SwirlOrb: View {
    var isActive: Bool = false
    var isThinking: Bool = false
    var intensity: CGFloat = 0
    var size: CGFloat = 250

    private let loopCount = 9

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = isActive ? 1.8 : (isThinking ? 1.3 : 0.65)
            let spin = t * 0.12 * speed                 // slow global rotation (radians)
            let breathe = 1.0 + sin(t * 1.1) * 0.015    // gentle idle pulse

            ZStack {
                // Outer bloom halo — fades fully to clear inside the frame (no hard edge).
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.glow.opacity(0.42), Theme.accent.opacity(0.12), .clear],
                            center: .center, startRadius: 0, endRadius: size * 0.60
                        )
                    )
                    .frame(width: size * 1.2, height: size * 1.2)
                    .blur(radius: 30)

                // Dim green glow filling the torus hole (center is darker, not bright).
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.accent.opacity(0.22), .clear],
                            center: .center, startRadius: 0, endRadius: size * 0.24
                        )
                    )
                    .frame(width: size * 0.55, height: size * 0.55)
                    .blur(radius: 16)

                // Woven light-loops: soft glow pass under a crisp pass.
                rosette(spin: spin).blur(radius: 9).opacity(0.85)
                rosette(spin: spin)
            }
            .frame(width: size * 1.3, height: size * 1.3)
            .scaleEffect(breathe * (1.0 + intensity * 0.07))
            .compositingGroup()
        }
    }

    /// N thin bright ellipses rotated evenly around the center → the woven torus.
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
        SwirlOrb(isActive: true, intensity: 0.3)
    }
    .preferredColorScheme(.dark)
}
