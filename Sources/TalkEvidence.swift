import Foundation

// Reproducible simulator actions use the same native controls as taps.
// Explicit launch flags and the selected session are required; URLs carry no message text.
enum TalkEvidence {
    static let notification = Notification.Name("PocketNativeTalkEvidence")
    static func accept(_ url: URL) -> Bool {
        guard url.scheme == "pocketios", url.host == "evidence", url.query == nil, url.fragment == nil else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == TalkLaunch.argument("-PocketEvidenceTalk") else { return false }
        let action = parts[1]
        let dryActions = ["send", "fold", "foldCycle", "keyboard", "lines", "cancel", "retry"]
        guard TalkLaunch.dryRun && dryActions.contains(action) else { return false }
        NotificationCenter.default.post(name: notification, object: action)
        return true
    }
}
