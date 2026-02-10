// OpenVision - AnimatedBackground.swift
// Beautiful animated gradient background

import SwiftUI

/// Animated gradient background for the app
struct AnimatedBackground: View {
    @State private var animateGradient = false

    var body: some View {
        ZStack {
            // Base dark gradient
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.08),
                    Color(red: 0.05, green: 0.02, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Animated accent blobs
            GeometryReader { geometry in
                ZStack {
                    // Blue blob
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.blue.opacity(0.3),
                                    Color.blue.opacity(0)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.4
                            )
                        )
                        .frame(width: geometry.size.width * 0.8)
                        .offset(
                            x: animateGradient ? -geometry.size.width * 0.2 : geometry.size.width * 0.1,
                            y: animateGradient ? -geometry.size.height * 0.1 : geometry.size.height * 0.1
                        )
                        .blur(radius: 60)

                    // Purple blob
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.purple.opacity(0.25),
                                    Color.purple.opacity(0)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.5
                            )
                        )
                        .frame(width: geometry.size.width)
                        .offset(
                            x: animateGradient ? geometry.size.width * 0.2 : -geometry.size.width * 0.1,
                            y: animateGradient ? geometry.size.height * 0.3 : geometry.size.height * 0.2
                        )
                        .blur(radius: 80)

                    // Cyan accent
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.cyan.opacity(0.15),
                                    Color.cyan.opacity(0)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.3
                            )
                        )
                        .frame(width: geometry.size.width * 0.6)
                        .offset(
                            x: animateGradient ? geometry.size.width * 0.3 : geometry.size.width * 0.1,
                            y: animateGradient ? -geometry.size.height * 0.2 : geometry.size.height * 0.3
                        )
                        .blur(radius: 50)
                }
            }

            // Noise texture overlay for depth
            Rectangle()
                .fill(.white.opacity(0.02))
                .background(
                    Canvas { context, size in
                        // Simple noise pattern
                        for _ in 0..<100 {
                            let x = CGFloat.random(in: 0...size.width)
                            let y = CGFloat.random(in: 0...size.height)
                            let rect = CGRect(x: x, y: y, width: 1, height: 1)
                            context.fill(Path(rect), with: .color(.white.opacity(0.03)))
                        }
                    }
                )
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
