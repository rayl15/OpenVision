// OpenVision - AnimatedBackground.swift
// Beautiful animated gradient background

import SwiftUI

/// Animated gradient background for the app
struct AnimatedBackground: View {
    @State private var animateGradient = false

    var body: some View {
        ZStack {
            // Near-black base
            Theme.bg

            // Emerald ambient glow — brightest around the center, drifting slowly for life.
            GeometryReader { geometry in
                ZStack {
                    // Main center glow (sits behind the orb)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Theme.accent.opacity(0.28), Theme.accentDeep.opacity(0.12), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.55
                            )
                        )
                        .frame(width: geometry.size.width * 1.2)
                        .offset(
                            x: animateGradient ? geometry.size.width * 0.06 : -geometry.size.width * 0.06,
                            y: animateGradient ? -geometry.size.height * 0.04 : geometry.size.height * 0.02
                        )
                        .blur(radius: 70)

                    // Subtle top glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Theme.glow.opacity(0.18), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.4
                            )
                        )
                        .frame(width: geometry.size.width * 0.8)
                        .offset(x: 0, y: -geometry.size.height * (animateGradient ? 0.34 : 0.30))
                        .blur(radius: 60)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(
                .easeInOut(duration: 8)
                .repeatForever(autoreverses: true)
            ) {
                animateGradient = true
            }
        }
    }
}

/// Particle effect overlay
struct ParticleEffect: View {
    let particleCount: Int

    @State private var particles: [Particle] = []

    struct Particle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var size: CGFloat
        var opacity: CGFloat
        var speed: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for particle in particles {
                    let rect = CGRect(
                        x: particle.x * size.width,
                        y: particle.y * size.height,
                        width: particle.size,
                        height: particle.size
                    )
                    context.fill(
                        Circle().path(in: rect),
                        with: .color(.white.opacity(particle.opacity))
                    )
                }
            }
            .onAppear {
                generateParticles()
                startAnimation(size: geometry.size)
            }
        }
    }

    private func generateParticles() {
        particles = (0..<particleCount).map { _ in
            Particle(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                size: CGFloat.random(in: 1...3),
                opacity: CGFloat.random(in: 0.1...0.3),
                speed: CGFloat.random(in: 0.0001...0.0005)
            )
        }
    }

    private func startAnimation(size: CGSize) {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            for i in particles.indices {
                particles[i].y -= particles[i].speed
                if particles[i].y < 0 {
                    particles[i].y = 1
                    particles[i].x = CGFloat.random(in: 0...1)
                }
            }
        }
    }
}

#Preview {
    ZStack {
        AnimatedBackground()

        ParticleEffect(particleCount: 50)

        VStack {
            Text("OpenVision")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Beautiful Background")
                .foregroundColor(.white.opacity(0.7))
        }
    }
    .preferredColorScheme(.dark)
}
