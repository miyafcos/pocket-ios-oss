import SwiftUI
import UIKit

/// The harness composer's text box: a `UITextView` under SwiftUI, so that a
/// copied picture can be pasted into it. `TextField` cannot take one and
/// cannot be taught to; here the picture lands in `onImage` and any words that
/// came with it go in at the cursor, the same as the talk composer.
struct HermesComposerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    var onVideo: (NSItemProvider) -> Void = { _ in }
    var videoPaths: () -> [String] = { [] }
    let onImage: (UIImage) -> Void
    static let maxLines = 6

    /// Puts the keyboard away, wherever it was.
    @MainActor static func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ImagePasteTextView {
        let view = ImagePasteTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.delegate = context.coordinator
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = placeholder
        view.onPasteImage = onImage
        view.onPasteVideo = onVideo
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        let label = UILabel()
        label.text = placeholder
        label.font = view.font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        ])
        label.isHidden = !text.isEmpty
        context.coordinator.placeholder = label
        context.coordinator.recordRenderedPaths(view)
        return view
    }

    func updateUIView(_ view: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        // A programmatic change (a send clearing the draft) lands; a person's
        // own typing is already there, and Japanese being composed is left alone.
        if view.markedTextRange == nil {
            if view.text != text { view.text = text }
            context.coordinator.recordRenderedPaths(view)
        }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
        view.onPasteImage = onImage
        view.onPasteVideo = onVideo
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ImagePasteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let font = uiView.font else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let minimum = ceil(font.lineHeight) + 16
        let maximum = ceil(font.lineHeight * CGFloat(Self.maxLines)) + 16
        uiView.isScrollEnabled = fitting > maximum
        return CGSize(width: width, height: min(maximum, max(minimum, ceil(fitting))))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HermesComposerField
        var placeholder: UILabel?
        private var renderedPaths: Set<String> = []
        init(_ parent: HermesComposerField) { self.parent = parent }
        func recordRenderedPaths(_ textView: UITextView) {
            renderedPaths = Set(parent.videoPaths().filter { TalkAttachmentLines.contains($0, in: textView.text) })
        }
        func textViewDidChange(_ textView: UITextView) {
            let paths = parent.videoPaths()
            var value = textView.text ?? ""
            // A video can finish uploading while Japanese text is marked. Keep
            // that new path in the binding until UIKit can show it after commit.
            for path in renderedPaths.subtracting(paths) {
                value = TalkAttachmentLines.removing(path, from: value)
            }
            for path in paths where !renderedPaths.contains(path) && !TalkAttachmentLines.contains(path, in: value) {
                value = TalkAttachmentLines.adding(path, to: value)
            }
            parent.text = value
            if textView.markedTextRange == nil {
                let selection = textView.selectedRange
                if textView.text != value {
                    textView.text = value
                    textView.selectedRange = NSRange(location: min(selection.location, (value as NSString).length), length: 0)
                }
                recordRenderedPaths(textView)
            }
            placeholder?.isHidden = !value.isEmpty
        }
        func textViewDidEndEditing(_ textView: UITextView) { textViewDidChange(textView) }
    }
}

enum HermesPastedImage {
    /// The same reduction and shape the harness photo picker produces: a JPEG
    /// as a data URL inside the message. Nil when even the reduced picture is
    /// over the limit.
    static func dataURL(_ image: UIImage) -> String? {
        TalkAttachment.jpeg(image).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }
}
