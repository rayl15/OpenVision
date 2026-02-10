// OpenVision - GlassCard.swift
// Beautiful glassmorphic card component for dark mode

import SwiftUI

/// A glassmorphic card with frosted blur effect
struct GlassCard<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = 20
    var opacity: CGFloat = 0.15
    var blurRadius: CGFloat = 10

    init(
        cornerRadius: CGFloat = 20,
        opacity: CGFloat = 0.15,
        blurRadius: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.blurRadius = blurRadius
    }

    var body: some View {
        content
            .background(
                ZStack {
                    // Blur background
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)

                    // Subtle gradient overlay
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(opacity),
                                    Color.white.opacity(opacity * 0.3)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Border glow
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// A glowing orb button for primary actions
struct GlowingOrbButton: View {
    let isActive: Bool
    let isProcessing: Bool
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: CGFloat = 0.5

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                accentColor.opacity(glowOpacity * 0.6),
                                accentColor.opacity(0)
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulseScale)

                // Middle ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                accentColor.opacity(0.8),
                                accentColor.opacity(0.4)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulseScale * 0.95)

                // Inner circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accentColor,
                                accentColor.opacity(0.7)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: accentColor.opacity(0.5), radius: 20)

                // Icon
                Image(systemName: isActive ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            startAnimations()
        }
        .onChange(of: isActive) { _ in
            startAnimations()
        }
        .onChange(of: isProcessing) { _ in
            startAnimations()
        }
    }

    private var accentColor: Color {
        if isActive {
            return isProcessing ? .purple : .blue
        }
        return .blue
    }

    private func startAnimations() {
        if isActive {
            // Pulsing animation when active
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                pulseScale = 1.1
                glowOpacity = 0.8
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                pulseScale = 1.0
                glowOpacity = 0.5
            }
        }
    }
}

/// Animated waveform visualizer
struct WaveformVisualizer: View {
    let isActive: Bool
    let intensity: CGFloat

    @State private var phase: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let amplitude = isActive ? (size.height / 3) * intensity : size.height / 8

            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY))

            for x in stride(from: 0, through: size.width, by: 2) {
                let relativeX = x / size.width
                let sine = sin((relativeX * 4 * .pi) + phase)
                let y = midY + (sine * amplitude)
                path.addLine(to: CGPoint(x: x, y: y))
            }

            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.blue.opacity(0.8),
                        Color.purple.opacity(0.8),
                        Color.blue.opacity(0.8)
                    ]),
                    startPoint: CGPoint(x: 0, y: midY),
                    endPoint: CGPoint(x: size.width, y: midY)
                ),
                lineWidth: 3
            )
        }
        .onAppear {
            startAnimation()
        }
        .onChange(of: isActive) { _ in
            startAnimation()
        }
    }

    private func startAnimation() {
        if isActive {
            withAnimation(
                .linear(duration: 2)
                .repeatForever(autoreverses: false)
            ) {
                phase = 2 * .pi
            }
        }
    }
}

/// Status pill showing connection state
struct StatusPill: View {
    let status: String
    let color: Color
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(isConnected ? 1.5 : 1)
                        .opacity(isConnected ? 0 : 1)
                        .animation(
                            isConnected ?
                                .easeOut(duration: 1).repeatForever(autoreverses: false) :
                                .none,
                            value: isConnected
                        )
                )

            Text(status)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

/// Floating action button with glow
struct FloatingActionButton: View {
    let icon: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Glow
                Circle()
                    .fill(color.opacity(isEnabled ? 0.3 : 0.1))
                    .frame(width: 70, height: 70)
                    .blur(radius: 10)

                // Button
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(isEnabled ? 0.8 : 0.3),
                                color.opacity(isEnabled ? 0.6 : 0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )

                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.white.opacity(isEnabled ? 1 : 0.5))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

#Preview {
    ZStack {
        // Dark gradient background
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.05, blue: 0.15),
                Color(red: 0.1, green: 0.05, blue: 0.2)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack(spacing: 30) {
            StatusPill(status: "OpenClaw", color: .green, isConnected: true)

            GlassCard {
                VStack(spacing: 12) {
                    Text("Glassmorphic Card")
                        .font(.headline)
                    Text("Beautiful frosted glass effect")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            }

            WaveformVisualizer(isActive: true, intensity: 0.8)
                .frame(height: 60)
                .padding(.horizontal)

            GlowingOrbButton(isActive: true, isProcessing: false) {}

            HStack(spacing: 20) {
                FloatingActionButton(icon: "camera.fill", color: .blue, isEnabled: true) {}
                FloatingActionButton(icon: "waveform", color: .purple, isEnabled: false) {}
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
