import UIKit
import UserNotifications

/// The "Tap to resume" notification for when the Spotify app is asleep and
/// can't be started remotely. Tapping it opens WatchTune, which calls
/// `onTap` (WatchTune then opens Spotify and starts playback).
final class ResumeNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onTap: (() -> Void)?
    private let center = UNUserNotificationCenter.current()
    private let id = "watchtune.resume"

    override init() {
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post() {
        let content = UNMutableNotificationContent()
        content.title = "Spotify is asleep"
        content.body = "Tap to resume playback from your watch."
        content.sound = .default
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func clear() {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == id {
            DispatchQueue.main.async { self.onTap?() }
        }
        completionHandler()
    }

    /// Show it even while WatchTune is open
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
