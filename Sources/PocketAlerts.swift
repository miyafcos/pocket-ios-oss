import Foundation
import UIKit
import UserNotifications

// Being told, instead of having to look. CC Pocket fires four kinds of push from
// its Bridge (websocket.ts maybeSendPushNotification) and falls back to a local
// notification when push is not ready (notification_service.dart).
// Real push needs the paid Apple Developer Program, which this app does not have,
// so only the fallback is built: while the app is in the background the poll
// keeps running for a while, and what it finds is raised here.
@MainActor final class PocketAlerts {
    static let shared = PocketAlerts()
    static let category = "pocket.waiting"
    private(set) var allowed = false
    private var announced: [String: Double] = [:]
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?
    var enabled: Bool {
        get { defaults.object(forKey: "alerts.enabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "alerts.enabled") }
    }
    init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter? = .current()) {
        self.defaults = defaults; self.center = center
    }
    func ask() async {
        guard enabled, let center else { return }
        allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    // The room's own name is the title; the preview line is masked the same way
    // the list masks it, because this text can land on a locked screen.
    nonisolated static func body(_ entry: SituationEntry, preview: String) -> String {
        let value = SessionPreview.mask(preview).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(String.UnicodeScalarView(value.unicodeScalars.prefix(120)))
    }
    nonisolated static func identifier(_ entry: SituationEntry) -> String { "waiting:" + entry.id }
    // Only rooms that are waiting for an answer, and only once per turn: the same
    // room speaking again later is a new time, so it is raised again.
    func fresh(_ entry: SituationEntry) -> Bool {
        guard let time = Situation.situationTime(entry.tab) else { return false }
        guard let last = announced[entry.id] else { return true }
        return time > last
    }
    func raise(_ entries: [SituationEntry], lines: [String: PreviewLine], badge: Int) {
        guard enabled, allowed, let center else { return }
        for entry in entries where fresh(entry) {
            announced[entry.id] = Situation.situationTime(entry.tab) ?? Date().timeIntervalSince1970 * 1000
            let content = UNMutableNotificationContent()
            content.title = Situation.displayTitle(Situation.firstNonempty(entry.tab.title, entry.tab.label))
            content.body = Self.body(entry, preview: SessionPreview.text(
                tab: entry.tab, lines: lines, workspace: entry.workspaceName))
            content.sound = .default
            content.categoryIdentifier = Self.category
            if let key = SessionPreview.key(entry.tab), !key.hasPrefix("term:") {
                content.userInfo = ["talk": key]
            }
            center.add(UNNotificationRequest(identifier: Self.identifier(entry), content: content, trigger: nil))
        }
        setBadge(badge)
    }
    func setBadge(_ count: Int) { center?.setBadgeCount(max(0, count)) }
    // Opening the app is the reader catching up: clear what is already seen.
    func clearDelivered() {
        center?.removeAllDeliveredNotifications()
        setBadge(0)
    }
    // While a room is open on screen it does not need to announce itself.
    func silence(_ talk: String) { announced["open:" + talk] = 0 }
}
// The notification's tap lands on the same deep link the app already knows.
final class PocketAlertDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // Touched only from the notification centre's callbacks and the app's setup.
    nonisolated(unsafe) static let shared = PocketAlertDelegate()
    var onOpen: (@MainActor (String) -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse) async {
        guard let talk = response.notification.request.content.userInfo["talk"] as? String else { return }
        await MainActor.run { self.onOpen?(talk) }
    }
    // The app is open and the reader is already looking: no banner over the screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.badge]
    }
}
