import SwiftUI
import UIKit

/// The pictures in the harness room.
///
/// A row just sent from this phone carries its pictures as the data URLs it
/// attached; a transcript row carries the URLs of the pictures the server kept
/// when they were sent. Both are drawn here -- the first decoded on the spot, the
/// second fetched through the room's own session -- and cached by source, so a
/// row scrolling back into view costs nothing. Hermes's own transcript keeps only
/// a placeholder per picture, which is what the room used to show (2026-09-16).
@MainActor
final class HermesImageLoader {
    static let shared = HermesImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        // Reading-size pictures; a long room with many is still a few dozen.
        cache.countLimit = 60
    }

    /// The picture for a source, or nil when it cannot be drawn. One fetch per
    /// source at a time: a grid of the same picture twice asks once.
    func image(for source: String, session: URLSession = TalkSession.shared) async -> UIImage? {
        if let hit = cache.object(forKey: source as NSString) { return hit }
        if let running = inFlight[source] { return await running.value }
        let task = Task<UIImage?, Never> {
            if let decoded = Self.decode(dataURL: source) { return decoded }
            guard let url = URL(string: source), let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }
            guard let answer = try? await session.data(from: url),
                  let http = answer.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return UIImage(data: answer.0)
        }
        inFlight[source] = task
        let image = await task.value
        inFlight[source] = nil
        if let image { cache.setObject(image, forKey: source as NSString) }
        return image
    }

    /// A picture out of a `data:image/…;base64,` URL, or nil for anything else.
    nonisolated static func decode(dataURL: String) -> UIImage? {
        guard dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }
}

/// Pictures the harness put inside its reply.
///
/// A reply that hands back a file arrives with the file as a markdown image whose
/// source is a data URL (the API server resolves a MEDIA path to one on the way
/// out). Drawn as a picture rather than shown as a wall of base64. A markdown
/// image that only names a path on the Mac is left in the words: nothing here
/// can fetch it, and a name is more honest than a broken frame.
enum HermesInlineImages {
    // Built per call: a Regex is not Sendable, so it cannot be a shared constant.
    private static var inline: Regex<(Substring, Substring)> {
        #/!\[[^\]]*\]\((data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+)\)/#
    }

    static func split(_ text: String) -> (text: String, images: [String]) {
        let pattern = inline
        let images = text.matches(of: pattern).map { String($0.output.1) }
        guard !images.isEmpty else { return (text, []) }
        // The blank lines that framed a lifted picture would otherwise stay as a gap.
        let remaining = text.replacing(pattern, with: "")
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (remaining, images)
    }
}

/// The pictures on a message, in the bubble's own shape: one picture at reading
/// size, several as a grid of squares. Any of them opens large on a tap.
struct HermesPictureGrid: View {
    let sources: [String]
    /// Mine sit on the right, the harness's on the left, like the words.
    var trailing = false

    private static let single = CGSize(width: 220, height: 280)
    private static let square: CGFloat = 108
    private static let gap: CGFloat = 6

    var body: some View {
        if sources.count == 1 {
            HermesPicture(source: sources[0], maxWidth: Self.single.width, maxHeight: Self.single.height)
        } else {
            let columns = [GridItem(.fixed(Self.square), spacing: Self.gap), GridItem(.fixed(Self.square), spacing: Self.gap)]
            LazyVGrid(columns: columns, alignment: trailing ? .trailing : .leading, spacing: Self.gap) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    HermesPicture(source: source, maxWidth: Self.square, maxHeight: Self.square, fill: true)
                }
            }
            .frame(width: Self.square * 2 + Self.gap)
        }
    }
}

/// One picture in the room: loading, drawn, or missing -- and large on a tap.
struct HermesPicture: View {
    let source: String
    var maxWidth: CGFloat = 220
    var maxHeight: CGFloat = 280
    /// A square in a grid crops to fill; a picture on its own fits whole.
    var fill = false

    @State private var image: UIImage?
    @State private var missing = false
    @State private var enlarged = false

    private static let corner: CGFloat = 12

    var body: some View {
        Group {
            if let image, fill {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: maxWidth, height: maxHeight).clipped()
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            } else {
                RoundedRectangle(cornerRadius: Self.corner)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: fill ? maxWidth : 160, height: fill ? maxHeight : 120)
                    .overlay {
                        if missing {
                            Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .contentShape(RoundedRectangle(cornerRadius: Self.corner))
        .onTapGesture { if image != nil { enlarged = true } }
        .accessibilityLabel(missing ? "読み込めなかった画像" : "画像")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("hermes.image")
        .task(id: source) {
            image = await HermesImageLoader.shared.image(for: source)
            missing = image == nil
        }
        .fullScreenCover(isPresented: $enlarged) {
            if let image { HermesPictureViewer(image: image) }
        }
    }
}

/// One picture, large, on its own: pinch to zoom, double-tap to toggle, a button
/// to come back.
struct HermesPictureViewer: View {
    let image: UIImage
    var identifierPrefix = "hermes"
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in scale = settled * value.magnification }
                        .onEnded { _ in
                            settled = min(max(scale, 1), 4)
                            withAnimation(.easeOut(duration: 0.15)) { scale = settled }
                        }
                )
                .onTapGesture(count: 2) {
                    settled = settled > 1 ? 1 : 2.5
                    withAnimation(.easeOut(duration: 0.2)) { scale = settled }
                }
                .accessibilityLabel("画像")
                .accessibilityIdentifier("\(identifierPrefix).image.large")
            Button("閉じる") { dismiss() }
                .font(PocketType.text)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding()
                .accessibilityIdentifier("\(identifierPrefix).image.close")
        }
        .preferredColorScheme(.dark)
    }
}

/// What is attached, before it is sent: the pictures themselves, each with its
/// own remove, and one control that drops them all. "画像 N 枚" said how many and
/// showed none (2026-09-16).
struct HermesAttachmentStrip: View {
    @Binding var attachments: [String]

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, source in
                        ZStack(alignment: .topTrailing) {
                            HermesThumbnail(source: source)
                            Button {
                                if attachments.indices.contains(index) { attachments.remove(at: index) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.65))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("この画像を外す")
                            .accessibilityIdentifier("hermes.attach.remove")
                        }
                        .padding(.top, 6).padding(.trailing, 6)
                    }
                }
            }
            Button("外す") { attachments = [] }
                .font(PocketType.small)
                .accessibilityIdentifier("hermes.attach.clear")
        }
    }
}

/// A picture about to be sent, at strip size. Decoded through the loader, so
/// the composer re-rendering on every keystroke does not decode it again.
private struct HermesThumbnail: View {
    let source: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("付けた画像")
        .accessibilityIdentifier("hermes.attach.thumb")
        .task(id: source) { image = await HermesImageLoader.shared.image(for: source) }
    }
}
