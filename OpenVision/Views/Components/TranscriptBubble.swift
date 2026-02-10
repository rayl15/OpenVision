// OpenVision - TranscriptBubble.swift
// Beautiful message bubbles for transcripts

import SwiftUI

/// Animated typing indicator
struct TypingIndicator: View {
    @State private var animationOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .offset(y: animationOffset(for: index))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.6)
                .repeatForever(autoreverses: true)
            ) {
                animationOffset = -8
            }
        }
    }

    private func animationOffset(for index: Int) -> CGFloat {
        let delay = Double(index) * 0.15
        return animationOffset * cos(delay * .pi)
    }
}

/// Transcript bubble for user or AI messages
struct TranscriptBubble: View {
    let text: String
    let isUser: Bool
    let isStreaming: Bool

    @State private var displayedText: String = ""
    @State private var streamingIndex: Int = 0

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Label
                Text(isUser ? "You" : "AI")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(isUser ? .blue.opacity(0.8) : .purple.opacity(0.8))
                    .textCase(.uppercase)
                    .tracking(1)

                // Message bubble
                Text(isStreaming ? displayedText : text)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        ZStack {
                            // Gradient background
                            RoundedRectangle(cornerRadius: 20)
                                .fill(
                                    LinearGradient(
                                        colors: isUser ? [
                                            Color.blue.opacity(0.6),
                                            Color.blue.opacity(0.4)
                                        ] : [
                                            Color.purple.opacity(0.4),
                                            Color.purple.opacity(0.2)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            // Glass overlay
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.ultraThinMaterial.opacity(0.3))

                            // Border
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(
                                    Color.white.opacity(isUser ? 0.3 : 0.15),
                                    lineWidth: 1
                                )
                        }
                    )
                    .shadow(color: (isUser ? Color.blue : Color.purple).opacity(0.2), radius: 10)
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .onAppear {
            if isStreaming {
                startStreaming()
            }
        }
        .onChange(of: text) { newText in
            if isStreaming {
                streamNewText(newText)
            }
        }
    }

    private func startStreaming() {
        displayedText = ""
        streamingIndex = 0
        streamCharacter()
    }

    private func streamCharacter() {
        guard streamingIndex < text.count else { return }

        let index = text.index(text.startIndex, offsetBy: streamingIndex)
        displayedText.append(text[index])
        streamingIndex += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            streamCharacter()
        }
    }

    private func streamNewText(_ newText: String) {
        // Append new characters
        let newChars = String(newText.dropFirst(displayedText.count))
        for char in newChars {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(displayedText.count) * 0.01) {
                displayedText.append(char)
            }
        }
    }
}

/// Transcript view showing conversation
struct TranscriptView: View {
    let userText: String
    let aiText: String
    let isAIStreaming: Bool

    var body: some View {
        VStack(spacing: 16) {
            if !userText.isEmpty {
                TranscriptBubble(text: userText, isUser: true, isStreaming: false)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if !aiText.isEmpty {
                TranscriptBubble(text: aiText, isUser: false, isStreaming: isAIStreaming)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if isAIStreaming {
                HStack {
                    TypingIndicator()
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: userText)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: aiText)
    }
}

/// Tool status indicator
struct ToolStatusView: View {
    let toolName: String
    let isRunning: Bool

    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            // Animated icon
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.subheadline)
                .foregroundColor(.orange)
                .rotationEffect(.degrees(isRunning ? rotation : 0))

            Text(toolName)
                .font(.subheadline)
                .fontWeight(.medium)

            if isRunning {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.orange)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.2))
                .overlay(
                    Capsule()
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
        )
        .onAppear {
            if isRunning {
                withAnimation(
                    .linear(duration: 2)
                    .repeatForever(autoreverses: false)
                ) {
                    rotation = 360
                }
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 24) {
            TranscriptView(
                userText: "Hey Vision, what's the weather like today?",
                aiText: "Based on your location, it's currently 72°F and sunny. Perfect weather for being outside!",
                isAIStreaming: false
            )

            TypingIndicator()

            ToolStatusView(toolName: "weather_lookup", isRunning: true)
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
