import PhotosUI
import SwiftUI

/// Attaching a picture to the harness room: from the photo library, or pasted
/// from the board (a screenshot, a picture copied in another app).
///
/// Either way the picture goes through `TalkAttachment`, the same reduction the
/// talk screen and the web app use, so one full-size phone photo cannot be the
/// difference between a message that sends and a 413. It travels as a data URL
/// inside the message rather than as a separate upload, because that is the
/// shape Hermes reads multimodal content in.
struct HermesAttachButton: View {
    @Binding var attachments: [String]
    @Binding var draft: String
    var videoBusy = false
    var onVideo: (NSItemProvider) -> Void = { _ in }
    @State private var pickingVideo = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var picking = false
    @State private var busy = false

    /// The room's own cap, checked here so the person is stopped at the button
    /// rather than by a refusal after they have typed.
    static let limit = 4

    var body: some View {
        Menu {
            Button("写真を選ぶ", systemImage: "photo") { picking = true }
                .disabled(attachments.count >= Self.limit)
            Button("動画を選ぶ", systemImage: "video") { pickingVideo = true }
            // Only `hasImages` is asked while the menu is built; the board is
            // read when the entry is chosen, which is when iOS may say so.
            Button("画像を貼り付け", systemImage: "doc.on.clipboard") { paste() }
                .disabled(attachments.count >= Self.limit || !TalkPaste.canPasteImage())
            Button("動画を貼り付け", systemImage: "doc.on.clipboard") { paste(preferVideo: true) }
                .disabled(!TalkPaste.canPasteVideo())
        } label: {
            Image(systemName: busy ? "hourglass" : "photo.on.rectangle")
                .font(.system(size: 22))
                .foregroundStyle(attachments.count >= Self.limit ? Color.secondary.opacity(0.4) : HermesLook.accent)
                .frame(width: 34, height: 34)
        }
        .disabled(busy || videoBusy)
        .accessibilityLabel("画像を付ける")
        .accessibilityIdentifier("hermes.attach")
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: Self.limit, matching: .images)
        .sheet(isPresented: $pickingVideo) { VideoPicker(onSelect: onVideo) }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await adopt(items) }
        }
    }

    private func adopt(_ items: [PhotosPickerItem]) async {
        busy = true
        defer { busy = false; picked = [] }
        var added: [String] = []
        for item in items.prefix(Self.limit - attachments.count) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = TalkAttachment.jpeg(image) else { continue }
            added.append("data:image/jpeg;base64," + jpeg.base64EncodedString())
        }
        attachments.append(contentsOf: added)
    }

    /// The menu has no cursor to put words at, so they go on the end of the
    /// draft; the picture is attached like a picked one.
    private func paste(preferVideo: Bool = false) {
        let paste = TalkPaste.take(preferVideo: preferVideo)
        if let text = paste.text { draft = draft.isEmpty ? text : draft + text }
        if let image = paste.image { Self.attach(image, to: &attachments) }
        if let video = paste.video { onVideo(video) }
    }

    /// A pasted picture into the room's list, if there is room and it reduces
    /// under the limit. Returns whether it went in.
    @discardableResult
    static func attach(_ image: UIImage, to attachments: inout [String]) -> Bool {
        guard attachments.count < limit, let url = HermesPastedImage.dataURL(image) else { return false }
        attachments.append(url)
        return true
    }
}
