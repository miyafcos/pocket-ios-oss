import SwiftUI
import UIKit

struct TalkImageContent: Equatable {
    var text: String
    var paths: [String]

    static func split(_ text: String) -> TalkImageContent {
        let pattern = #"^(?:[A-Za-z]:[\\/]|/).*[\\/]uploads[\\/]([0-9]{8})[\\/]\1T[0-9]{6}Z-[0-9a-f]{8}\.(?:jpg|png|gif|webp)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return .init(text: text, paths: [])
        }
        var paths: [String] = []
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            var candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("`"), candidate.hasSuffix("`"), candidate.count > 2 {
                candidate = String(candidate.dropFirst().dropLast())
            }
            if regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                if !paths.contains(candidate) { paths.append(candidate) }
            } else {
                lines.append(line)
            }
        }
        return .init(text: paths.isEmpty ? text : lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), paths: paths)
    }
}

struct TalkSentImages: View {
    let paths: [String]
    let base: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(paths, id: \.self) { path in
                if let url = FileOpen.contentURL(base: base, path: path) {
                    TalkSentImage(source: url.absoluteString)
                }
            }
        }
    }
}

private struct TalkSentImage: View {
    let source: String
    @State private var image: UIImage?
    @State private var missing = false
    @State private var enlarged = false
    @State private var attempt = 0

    var body: some View {
        Button {
            if image != nil { enlarged = true }
            else if missing { attempt += 1 }
        } label: {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 280)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 160, height: 120)
                        .overlay {
                            if missing { Label("再読み込み", systemImage: "photo.badge.exclamationmark") }
                            else { ProgressView() }
                        }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(missing ? "画像を再読み込み" : image == nil ? "画像を読み込み中" : "添付画像を拡大")
        .accessibilityValue(image != nil ? "読み込み済み" : missing ? "読み込み失敗" : "読み込み中")
        .accessibilityIdentifier("talk.image")
        .task(id: "\(source)#\(attempt)") {
            image = nil
            missing = false
            image = await HermesImageLoader.shared.image(for: source)
            missing = image == nil
        }
        .fullScreenCover(isPresented: $enlarged) {
            if let image { HermesPictureViewer(image: image, identifierPrefix: "talk") }
        }
    }
}
