// OpenVision - MainTabView.swift
// Main tab navigation: Voice Agent, History, Settings

import SwiftUI

struct MainTabView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager
    @EnvironmentObject var conversationManager: ConversationManager

    // MARK: - State

    @State private var selectedTab: Tab = .voice

    // MARK: - Tab Enum

    enum Tab: String, CaseIterable {
        case voice = "Voice"
        case history = "History"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .voice: return "waveform.circle.fill"
            case .history: return "clock.fill"
            case .settings: return "gearshape.fill"
            }
        }

        var selectedIcon: String {
            switch self {
            case .voice: return "waveform.circle.fill"
            case .history: return "clock.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        TabView(selection: $selectedTab) {
            // Voice Agent Tab
            VoiceAgentView()
                .tabItem {
                    Label(Tab.voice.rawValue, systemImage: Tab.voice.icon)
                }
                .tag(Tab.voice)

            // History Tab
            ConversationListView()
                .tabItem {
                    Label(Tab.history.rawValue, systemImage: Tab.history.icon)
                }
                .tag(Tab.history)

            // Settings Tab
            SettingsView()
                .tabItem {
                    Label(Tab.settings.rawValue, systemImage: Tab.settings.icon)
                }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .onAppear {
            // Customize tab bar appearance for dark mode
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(white: 0.05, alpha: 0.95)

            // Normal state
            appearance.stackedLayoutAppearance.normal.iconColor = .gray
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.gray]

            // Selected state — emerald accent (matches Theme.accent)
            let accent = UIColor(red: 0.16, green: 0.85, blue: 0.47, alpha: 1)
            appearance.stackedLayoutAppearance.selected.iconColor = accent
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: accent]

            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .environmentObject(ConversationManager.shared)
        .preferredColorScheme(.dark)
}
