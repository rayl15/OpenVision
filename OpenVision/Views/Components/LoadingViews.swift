// OpenVision - LoadingViews.swift
// Beautiful loading and activity indicators

import SwiftUI

// MARK: - Pulsing Loader

/// Animated pulsing circles loading indicator
struct PulsingLoader: View {
    @State private var isAnimating = false

    let color: Color
    let size: CGFloat

    init(color: Color = .blue, size: CGFloat = 60) {
        self.color = color
        self.size = size
    }

    var body: some View {
        ZStack {
            // Outer pulse ring
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(isAnimating ? 1.5 : 1.0)
                .opacity(isAnimating ? 0 : 1)

            // Middle pulse ring
            Circle()
                .stroke(color.opacity(0.5), lineWidth: 2)
                .frame(width: size * 0.7, height: size * 0.7)
                .scaleEffect(isAnimating ? 1.3 : 1.0)
                .opacity(isAnimating ? 0 : 1)

            // Center dot
            Circle()
                .fill(color)
                .frame(width: size * 0.3, height: size * 0.3)
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Orbit Loader

/// Animated orbiting dots loader
struct OrbitLoader: View {
    @State private var rotation: Double = 0

    let color: Color
    let size: CGFloat

    init(color: Color = .blue, size: CGFloat = 50) {
        self.color = color
        self.size = size
    }

    var body: some View {
        ZStack {
            // Orbiting dots
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: size * 0.15, height: size * 0.15)
                    .offset(y: -size * 0.35)
                    .rotationEffect(.degrees(rotation + Double(index) * 120))
                    .opacity(0.3 + Double(index) * 0.35)
            }

            // Center glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.3), color.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.3
                    )
                )
                .frame(width: size * 0.6, height: size * 0.6)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(
                .linear(duration: 1.5)
                .repeatForever(autoreverses: false)
            ) {
                rotation = 360
            }
        }
    }
}

// MARK: - Wave Loader

/// Animated wave bars loader
struct WaveLoader: View {
    @State private var isAnimating = false

    let color: Color
    let barCount: Int
    let barWidth: CGFloat
    let height: CGFloat

    init(
        color: Color = .blue,
        barCount: Int = 5,
        barWidth: CGFloat = 4,
        height: CGFloat = 40
    ) {
        self.color = color
        self.barCount = barCount
        self.barWidth = barWidth
        self.height = height
    }

    var body: some View {
        HStack(spacing: barWidth) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: barWidth, height: barHeight(for: index))
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                        value: isAnimating
                    )
            }
        }
        .frame(height: height)
        .onAppear {
            isAnimating = true
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let baseHeight = height * 0.3
        let maxHeight = height
        return isAnimating ? maxHeight : baseHeight
    }
}

// MARK: - Connection Status Indicator

/// Status indicator with animated states
struct ConnectionStatusIndicator: View {
    let status: Status
    let size: CGFloat

    enum Status {
        case disconnected
        case connecting
        case connected
        case error

        var color: Color {
            switch self {
            case .disconnected: return .gray
            case .connecting: return .orange
            case .connected: return .green
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .disconnected: return "wifi.slash"
            case .connecting: return "wifi"
            case .connected: return "wifi"
            case .error: return "wifi.exclamationmark"
            }
        }
    }

    @State private var isAnimating = false

    init(status: Status, size: CGFloat = 24) {
        self.status = status
        self.size = size
    }

    var body: some View {
        ZStack {
            // Background pulse for connecting state
            if status == .connecting {
                Circle()
                    .fill(status.color.opacity(0.3))
                    .frame(width: size * 1.5, height: size * 1.5)
                    .scaleEffect(isAnimating ? 1.3 : 1.0)
                    .opacity(isAnimating ? 0 : 0.5)
            }

            // Main indicator
            Circle()
                .fill(status.color)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: status.icon)
                        .font(.system(size: size * 0.5))
                        .foregroundColor(.white)
                )
        }
        .onAppear {
            if status == .connecting {
                withAnimation(
                    .easeInOut(duration: 1.0)
                    .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
        }
        .onChange(of: status) { newStatus in
            if newStatus == .connecting {
                withAnimation(
                    .easeInOut(duration: 1.0)
                    .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            } else {
                isAnimating = false
            }
        }
    }
}

// MARK: - Skeleton Loader

/// Skeleton placeholder for loading content
struct SkeletonView: View {
    @State private var isAnimating = false

    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    init(width: CGFloat? = nil, height: CGFloat = 20, cornerRadius: CGFloat = 4) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                LinearGradient(
                    colors: [
                        Color.gray.opacity(0.2),
                        Color.gray.opacity(0.3),
                        Color.gray.opacity(0.2)
                    ],
                    startPoint: isAnimating ? .leading : .trailing,
                    endPoint: isAnimating ? .trailing : .leading
                )
            )
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
    }
}

// MARK: - Full Screen Loader

/// Full screen loading overlay with message
struct FullScreenLoader: View {
    let message: String
    let isVisible: Bool

    init(message: String = "Loading...", isVisible: Bool = true) {
        self.message = message
        self.isVisible = isVisible
    }

    var body: some View {
        if isVisible {
            ZStack {
                // Dimmed background
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                // Loader card
                VStack(spacing: 24) {
                    OrbitLoader(
                        color: .white,
                        size: 60
                    )

                    Text(message)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Previews

#Preview("Loaders") {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 48) {
            VStack(spacing: 8) {
                Text("Pulsing Loader")
                    .foregroundColor(.white)
                PulsingLoader(color: .blue, size: 60)
            }

            VStack(spacing: 8) {
                Text("Orbit Loader")
                    .foregroundColor(.white)
                OrbitLoader(color: .purple, size: 50)
            }

            VStack(spacing: 8) {
                Text("Wave Loader")
                    .foregroundColor(.white)
                WaveLoader(color: .green)
            }

            HStack(spacing: 32) {
                ConnectionStatusIndicator(status: .disconnected)
                ConnectionStatusIndicator(status: .connecting)
                ConnectionStatusIndicator(status: .connected)
                ConnectionStatusIndicator(status: .error)
            }
        }
    }
}
