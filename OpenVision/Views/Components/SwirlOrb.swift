// OpenVision - SwirlOrb.swift
// The assistant's identity: a clean orb of glowing emerald light-loops.
//
// Smooth continuous rings tilted on fixed 3D axes and slowly counter-rotating around a bright
// bloom — reads as a premium "AI orb" rather than random smears. `isActive` speeds it up
// (listening/speaking), `intensity` (0…1 audio level) makes it breathe. No drawingGroup — that
// was clipping the blur into a visible rectangle.

import SwiftUI

struct SwirlOrb: View {
    var isActive: Bool = false
    var isThinking: Bool = false
    var intensity: CGFloat = 0
    var size: CGFloat = 230

    private let ringCount = 4

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = isActive ? 1.9 : (isThinking ? 1.35 : 0.7)

            ZStack {
                // Outer bloom — fades fully to clear well inside the frame, so there's no hard edge.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.glow.opacity(0.55), Theme.accent.opacity(0.18), .clear],
                            center: .center, startRadius: 0, endRadius: size * 0.62
                        )
                    )
                    .frame(width: size * 1.25, height: size * 1.25)
                    .blur(radius: 26)

                // Glow pass (blurred) + crisp pass of the same loops → luminous but defined.
                loops(t: t, speed: speed)
                    .blur(radius: 9)
                    .opacity(0.9)
                loops(t: t, speed: speed)

                // Bright core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.95), Theme.accentBright.opacity(0.7), .clear],
                            center: .center, startRadius: 0, endRadius: size * 0.16
                        )
                    )
                    .frame(width: size * 0.4, height: size * 0.4)
                    .blur(radius: 6)
            }
            .frame(width: size * 1.35, height: size * 1.35)
            .scaleEffect(1.0 + intensity * 0.08)
            .compositingGroup()
        }
    }

    /// The interlocked light-loops: full circles, thin consistent stroke, tilted on fixed axes,
    /// each spinning slowly at a slightly different rate so they weave.
    @ViewBuilder
    private func loops(t: TimeInterval, speed: Double) -> some View {
        ZStack {
            ForEach(0..<ringCount, id: \.self) { i in
                let f = Double(i)
                let spin = t * (0.28 + f * 0.09) * speed
                Circle()
                    .stroke(Theme.ringGradient, style: StrokeStyle(lineWidth: size * 0.022, lineCap: .round))
                    .frame(width: size * 0.66, height: size * 0.66)
                    .rotation3DEffect(.degrees(60), axis: (x: 1, y: 0, z: 0))                 // tilt to an ellipse
                    .rotationEffect(.radians(spin + f * .pi / Double(ringCount)))              // spin + even offset
                    .rotation3DEffect(.degrees(f * 44), axis: (x: 0.2, y: 0.4, z: 1))          // fan the loops in 3D
            }
        }
    }
}

/// Compact line-art orb mark for the tab bar (two interlocked tilted rings).
struct SwirlMark: View {
    var size: CGFloat = 28
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round))
                .frame(width: size * 0.9, height: size * 0.9)
                .rotation3DEffect(.degrees(55), axis: (x: 1, y: 0, z: 0))
                .rotationEffect(.degrees(30))
            Circle()
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round))
                .frame(width: size * 0.9, height: size * 0.9)
                .rotation3DEffect(.degrees(55), axis: (x: 1, y: 0, z: 0))
                .rotationEffect(.degrees(-30))
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
