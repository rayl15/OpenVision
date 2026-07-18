// OpenVision - NotificationForegroundPresenter.swift
// Show timer/alarm/pomodoro notifications even while the app is open.
//
// By default iOS suppresses notification banners when the app is in the foreground. Since the user
// is usually looking at OpenVision when a timer fires, we implement `willPresent` to still show the
// banner + play the sound.

import UserNotifications

final class NotificationForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationForegroundPresenter()

    /// Call once at launch to receive foreground notifications.
    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // For our own timer/alarm/pomodoro alerts, also play an in-app chime — the notification's own
        // sound is suppressed while our audio session is active and doesn't sound in silent mode.
        let id = notification.request.identifier
        if id.hasPrefix("timer-") || id.hasPrefix("alarm-") || id.hasPrefix("pomodoro-") {
            Task { @MainActor in SoundService.shared.playAlert() }
        }
        completionHandler([.banner, .sound, .list])
    }
}
