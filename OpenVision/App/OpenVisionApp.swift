// OpenVision - OpenVisionApp.swift
// App entry point with URL scheme handling for Meta AI registration

import SwiftUI
import MWDATCore

@main
struct OpenVisionApp: App {
    // MARK: - State Objects

    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var glassesManager = GlassesManager.shared
    @StateObject private var conversationManager = ConversationManager.shared

    // MARK: - App Storage

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // MARK: - Initialization

    init() {
        // Show timer/alarm notifications even when the app is in the foreground.
        NotificationForegroundPresenter.shared.register()
        // Create the location manager on the main thread + warm the cache for contextual notes.
        LocationHelper.shared.prewarm()

        // Move the model store OUT of Caches before anything touches the hub. iOS may purge
        // Caches under storage pressure, which silently deleted downloaded model weights (the app
        // then re-downloaded ~GBs at "connecting…" time). Must run before any HubClient exists.
        GemmaLocalService.bootstrapModelStore()

        // Initialize Meta Wearables SDK
        do {
            try Wearables.configure()
            print("[OpenVisionApp] Wearables SDK configured")
        } catch {
            print("[OpenVisionApp] Failed to configure Wearables SDK: \(error)")
        }
        print("[OpenVisionApp] Initialized")
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    MainTabView()
                        .environmentObject(settingsManager)
                        .environmentObject(glassesManager)
                        .environmentObject(conversationManager)
                } else {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                handleURL(url)
            }
        }
    }

    // MARK: - URL Handling

    /// Handle URL callback from Meta AI app for glasses registration
    private func handleURL(_ url: URL) {
        print("[OpenVisionApp] Received URL: \(url)")

        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
                print("[OpenVisionApp] URL handled successfully")
            } catch {
                print("[OpenVisionApp] Error handling URL: \(error)")
            }
        }
    }
}
