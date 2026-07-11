// OpenVision - SwirlOrb.swift
// The assistant's identity: a swirling orb of luminous emerald light trails.
//
// Recreates the reference's glowing "vortex" — several trimmed rings rotating on offset 3D axes
// with additive blending, over a soft radial core. `isActive` speeds it up (listening/speaking),
// `intensity` (0…1 audio level) makes it breathe.

import SwiftUI

struct SwirlOrb: View {
    var isActive: Bool = false
    var isThinking: Bool = false
    var intensity: CGFloat = 0
    var size: CGFloat = 220

    private let ringCount = 5

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speedMul = isActive ? 2.1 : (isThinking ? 1.5 : 0.8)

            ZStack {
                // Soft luminous core
                Circle()
                    .fill(Theme.glowGradient(0.85))
                    .frame(width: size * 1.15, height: size * 1.15)
                    .blur(radius: 18)

                // Swirling light-trail rings
                ForEach(0..<ringCount, id: \.self) { i in
                    let f = Double(i)
                    let phase = t * (0.35 + f * 0.12) * speedMul
                    let ringSize = size * (0.52 + f * 0.085)

                    Circle()
                        .trim(from: 0.04, to: 0.82)
                        .stroke(
                            Theme.ringGradient,
                            style: StrokeStyle(lineWidth: size * (0.045 - f * 0.004), lineCap: .round)
                        )
                        .frame(width: ringSize, height: ringSize)
                        .rotation3DEffect(
                            .radians(phase),
                            axis: (x: cos(f * 1.3), y: sin(f * 1.9) + 0.3, z: 0.35)
                        )
                        .rotationEffect(.radians(phase * 0.5 + f))
                        .blur(radius: 1.5 + CGFloat(i) * 0.9)
                        .blendMode(.plusLighter)
                }

                // Bright center highlight
                Circle()
                    .fill(Theme.accentBright)
                    .frame(width: size * 0.14, height: size * 0.14)
                    .blur(radius: size * 0.06)
                    .blendMode(.plusLighter)
            }
            .scaleEffect(1.0 + intensity * 0.10)
            .frame(width: size * 1.3, height: size * 1.3)
            .drawingGroup()   // rasterize (Metal) — blur + additive blending stay smooth
        }
    }
}

/// Small line-art orb mark for the tab bar / compact contexts (two interlocked rings).
struct SwirlMark: View {
    var size: CGFloat = 28
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.1, to: 0.9)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotation3DEffect(.degrees(35), axis: (x: 1, y: 0.4, z: 0))
            Circle()
                .trim(from: 0.1, to: 0.9)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotation3DEffect(.degrees(-35), axis: (x: 1, y: -0.4, z: 0))
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    ZStack {
        Theme.bg.ignoresSafeArea()
        VStack(spacing: 40) {
            SwirlOrb(isActive: true, intensity: 0.4)
            SwirlMark(size: 40)
        }
    }
    .preferredColorScheme(.dark)
}
