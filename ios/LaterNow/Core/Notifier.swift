import Foundation
import UIKit
import UserNotifications

/// Tells you when new moments are ready while Later Now is in the background. One notification that updates as
/// batches finish ("42 new moments ready"), rather than one per batch. Nothing is shown while the app is open.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called when a notification is tapped, to open the feed.
    var onOpen: () -> Void = {}

    private var moments = 0
    private var videos = 0

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked the first time videos are added, when the reason is obvious.
    func ask() {
        Task {
            let c = UNUserNotificationCenter.current()
            if await c.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await c.requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    private var inBackground: Bool { UIApplication.shared.applicationState != .active }

    /// A batch finished. `left` is how many videos are still in the queue.
    func found(moments n: Int, videos v: Int, left: Int, title: String?) {
        guard n > 0, inBackground else { return }
        let first = moments == 0
        moments += n; videos += v
        var body = videos == 1 ? "From \(title.map { "“\($0)”" } ?? "1 video")." : "From \(videos) videos."
        body += left > 0 ? " \(left) more on the way." : " Everything is ready."
        post("moments", "\(moments) new moment\(moments == 1 ? "" : "s") ready", body, sound: first)
    }

    /// The free quota ran out while you were away.
    func paused(until text: String, left: Int) {
        guard inBackground, left > 0 else { return }
        post("quota", "Paused for now", "Gemini's free quota is used up. \(left) video\(left == 1 ? "" : "s") continue \(text).", sound: false)
    }

    /// Back in the app: what the notification said is on screen now.
    func clear() {
        moments = 0; videos = 0
        let c = UNUserNotificationCenter.current()
        c.removeAllDeliveredNotifications()
        c.setBadgeCount(0)
    }

    private func post(_ id: String, _ title: String, _ body: String, sound: Bool) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = sound ? .default : nil   // only the first one makes a sound; later batches update it quietly
        let r = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        await MainActor.run { onOpen() }
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
