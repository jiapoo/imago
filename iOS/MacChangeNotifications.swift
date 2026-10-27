import Foundation
import ImagoKit
import UserNotifications

/// Tells the user when their Mac has changes for this iPhone's photos (deletions to confirm, favorites,
/// albums) that arrived while Imago wasn't on screen, e.g. at an overnight backup. The Mac can't reach
/// the phone by itself; this is a local notification, posted when the changes arrive.
enum MacChangeNotifications {
    private static let identifier = "mac-changes"

    /// Asks once, after pairing: until then there's no Mac to hear from.
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// One notification for everything waiting, replacing an earlier one.
    static func post(_ changes: [LibraryChange], mac: String) {
        guard !changes.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = changes.count == 1 ? "\(mac) has a change for your photos" : "\(mac) has \(changes.count) changes for your photos"
        content.body = changes.prefix(3).map(\.summary).joined(separator: " · ")
            + (changes.count > 3 ? " · and \(changes.count - 3) more" : "")
            + (changes.contains { $0.action == .delete } ? ". Open Imago to confirm." : ". Open Imago to review.")
        content.sound = .default
        content.badge = NSNumber(value: changes.count)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// The app is on screen: the changes show there, so the notification and badge go.
    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.setBadgeCount(0)
    }
}
