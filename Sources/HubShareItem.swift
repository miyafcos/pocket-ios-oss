import UIKit

/// What the hub's 共有 sheet hands each destination.
///
/// コピー gets three lines a person can paste into a talk, so the seat can open
/// the document and read it (2026-09-16 21:40: 成果物→html→共有→copy を
/// セッションに貼って、その html について相談したい). Every other destination
/// (ファイルに保存, メール, AirDrop, …) still gets the HTML file it always got.
enum HubShareText {
    static var windowsRoot: String {
        UserDefaults.standard.string(forKey: "hub.windowsRoot") ?? ""
    }

    /// The index row's `p`, joined under the root with `\`. Leading slashes are
    /// dropped (a URL's path is "/docs/…", the index's `p` is "docs/…"); every
    /// other character, Japanese included, stays as it is.
    static func windowsPath(_ p: String) -> String {
        guard !windowsRoot.isEmpty else { return "" }
        let segments = p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        return ([windowsRoot] + segments).joined(separator: "\\")
    }

    /// The three lines コピー puts on the board, in this order: the title, the
    /// Windows path (the fast road for a seat on Windows), the URL (the fallback).
    /// The title is kept as it is, only folded onto one line, so the first line
    /// is always `成果物「…」` whatever characters the title carries.
    static func lines(title: String, path: String, url: URL) -> String {
        let folded = title.replacingOccurrences(of: #"[\r\n\u2028\u2029]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let shown = folded.isEmpty ? "ハブの資料" : folded
        return ["成果物「\(shown)」", path, url.absoluteString].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The one item the sheet is given. It answers with the three lines for コピー
/// and with the HTML file for everything else; the preview and the subject a
/// mail gets are the file and the title, as before.
final class HubShareItem: NSObject, UIActivityItemSource {
    let file: URL
    let title: String
    let text: String

    init(file: URL, title: String, text: String) {
        self.file = file; self.title = title; self.text = text
        super.init()
    }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { file }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        payload(for: activityType)
    }
    // The payload is independent of the sheet's UIKit and XPC lifetime.
    func payload(for activityType: UIActivity.ActivityType?) -> Any {
        activityType == .copyToPasteboard ? text : file
    }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }
}
