import AppKit
import MailEngine
import UserNotifications

/// New-mail banners and the Dock badge.
@MainActor
enum Notifier {
    /// UNUserNotificationCenter needs a real app bundle; `swift run` builds don't have one.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notify(_ messages: [MessageSummary], account: AccountConfig) {
        guard canNotify, !messages.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        if messages.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "\(messages.count) new messages"
            content.body = account.email
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        for message in messages {
            let content = UNMutableNotificationContent()
            content.title = message.senderDisplay
            content.subtitle = message.subjectDisplay
            content.body = message.snippet ?? account.email
            content.sound = .default
            content.threadIdentifier = account.id.uuidString
            center.add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
        }
    }

    static func setBadge(_ count: Int) {
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
