import UIKit
import UniformTypeIdentifiers

/// What the composers ask of the pasteboard: whether a picture is there, and
/// the picture and words themselves. `UIPasteboard.general` in the app; a fake
/// in tests, so no test reads or writes the simulator's own board.
///
/// Only the `has…` questions are asked while a menu is being built. Reading
/// `image` or `string` is what makes iOS show the "pasted from …" banner, so
/// those are read once, when a person has actually chosen to paste.
@MainActor protocol PasteboardReading {
    var hasImages: Bool { get }
    var hasStrings: Bool { get }
    var hasVideos: Bool { get }
    func readVideo() -> NSItemProvider?
    func readImage() -> UIImage?
    func readString() -> String?
}

extension PasteboardReading {
    var hasVideos: Bool { false }
    func readVideo() -> NSItemProvider? { nil }
}

extension UIPasteboard: PasteboardReading {
    var hasVideos: Bool {
        contains(pasteboardTypes: [UTType.movie.identifier, UTType.mpeg4Movie.identifier, UTType.quickTimeMovie.identifier])
    }
    func readVideo() -> NSItemProvider? {
        itemProviders.first { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
    }
    func readImage() -> UIImage? { image }
    func readString() -> String? { string }
}

@MainActor enum TalkPasteboard {
    /// The board every composer looks at. Tests put a fake here.
    static var current: any PasteboardReading = UIPasteboard.general
}

/// What one paste brings in: the words, the picture, or both. Copying from a
/// web page or a note often carries both; the words go in at the cursor and
/// the picture is attached, the same as if each had been pasted alone.
struct TalkPaste {
    var text: String?
    var image: UIImage?
    var video: NSItemProvider?

    @MainActor static func canPasteImage(_ board: any PasteboardReading = TalkPasteboard.current) -> Bool {
        board.hasImages
    }
    @MainActor static func canPasteVideo(_ board: any PasteboardReading = TalkPasteboard.current) -> Bool {
        board.hasVideos
    }
    /// Reads the board. Call it from a tap, not from a menu builder (see above).
    @MainActor static func take(_ board: any PasteboardReading = TalkPasteboard.current, preferVideo: Bool = true) -> TalkPaste {
        var paste = TalkPaste()
        if preferVideo && board.hasVideos { paste.video = board.readVideo() }
        else if board.hasImages { paste.image = board.readImage() }
        else if board.hasVideos { paste.video = board.readVideo() }
        if board.hasStrings, let text = board.readString(), !text.isEmpty { paste.text = text }
        return paste
    }
}

/// A text view that takes a picture from the pasteboard.
///
/// A plain UITextView offers ペースト only for words, so a copied screenshot had
/// no way in (the web app has the same wall: WebKit never fires paste for an
/// image-only board in a textarea). Here the edit menu shows ペースト whenever
/// the board holds a picture, and pasting hands the picture to `onPasteImage`
/// while any words that came with it are typed in at the cursor.
final class ImagePasteTextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?
    var onPasteVideo: ((NSItemProvider) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), TalkPasteboard.current.hasImages || TalkPasteboard.current.hasVideos { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = TalkPasteboard.current
        guard board.hasImages || board.hasVideos else { super.paste(sender); return }
        let paste = TalkPaste.take(board)
        if let text = paste.text { insertPastedText(text) }
        if let image = paste.image { onPasteImage?(image) }
        if let video = paste.video { onPasteVideo?(video) }
    }

    /// Words in at the cursor, with the delegate told the same way a keystroke
    /// tells it, so the draft and the send button follow.
    func insertPastedText(_ text: String) {
        insertText(text)
        delegate?.textViewDidChange?(self)
    }
}

extension TalkAttachment {
    /// A small copy for the strip above the input, made from the JPEG that
    /// was uploaded so the two can never differ.
    static let thumbnailSide: CGFloat = 120
    static func thumbnail(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, thumbnailSide / longest)
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: 0.8)
    }
}

/// The lines an attachment leaves in the draft: the server's path, on a line
/// of its own, which the seat reads to open the picture.
enum TalkAttachmentLines {
    static func adding(_ path: String, to draft: String) -> String {
        draft.isEmpty ? path : draft + "\n" + path
    }
    /// The first line that is exactly this path is taken out; anything the
    /// person typed around it stays.
    static func removing(_ path: String, from draft: String) -> String {
        var lines = draft.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == path }) else { return draft }
        lines.remove(at: index)
        // The blank a removed middle line leaves behind is not worth keeping.
        if lines.indices.contains(index), index > 0, lines[index].isEmpty, !lines[index - 1].isEmpty, lines.count > 1 {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }
    static func contains(_ path: String, in draft: String) -> Bool {
        draft.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == path }
    }
}
