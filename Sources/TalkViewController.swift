import SwiftUI
import UIKit
import os
import PhotosUI
import Observation

// UIKit owns the keyboard guide; SwiftUI owns the transcript. No Web bridge.
@MainActor final class TalkViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate {
    let store: TalkStore
    let motion: MotionSettings
    let input = ImagePasteTextView()
    let composer = UIView()
    private let placeholder = UILabel()
    private let attach = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private let slashButton = UIButton(type: .system)
    private let selectionStrip = UIStackView()
    private var selectionHeight: NSLayoutConstraint!
    private var sendWidth: NSLayoutConstraint!
    private var selectionSignature = ""
    // The pictures attached to the draft, one row each, above the input: until
    // this the only sign of one was its path in the text.
    private let attachmentStrip = UIStackView()
    private var seenVideoRevision = -1
    private var pickingVideo = false
    private var videoHeight: NSLayoutConstraint!
    private lazy var videoHost = UIHostingController(rootView: VideoAttachmentStrip(model: store.videos) { [weak self] id in
        self?.store.removeVideo(id)
    })
    private var inputTop: NSLayoutConstraint!
    /// Holds the attachment strip at zero while it has no rows. See rebuildAttachmentStrip().
    private var stripHeight: NSLayoutConstraint!
    private var seenAttachmentRevision = -1
    private var textHeight: NSLayoutConstraint!
    private var host: UIHostingController<TalkTranscriptView>!
    private var lastGeometry = ""
    /// The reader's distance to the end of the room while older lines are fetched.
    private var gapToEnd: CGFloat?
    private var seenOlderRevision = 0
    private var seenLoadingOlder = false
    private var commands: [String] = []
    private var seenDraftRevision = 0
    private var seenDeliveryRevision = -1
    private var hasPrompts = false
    private var deferredDraft: String?
    private var commandsKey: String { "talk.native.commands:\(store.base):\(store.sessionID)" }
    private let logger = Logger(subsystem: "dev.miyazaki.pocket", category: "TalkNative")
    init(store: TalkStore, motion: MotionSettings) { self.store = store; self.motion = motion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        host = UIHostingController(rootView: TalkTranscriptView(motion: motion, store: store))
        host.safeAreaRegions = []
        addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .systemBackground
        host.view.accessibilityIdentifier = "talk.body"
        buildComposer()
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8)
        ])
        // Belt and braces after 2026-09-19: whatever the composer decides it
        // needs, the room keeps half the screen. Three attachment rows and a
        // six-line input come to about 340 points, so this never fights real
        // content -- it only refuses to let the composer take the room.
        let cap = composer.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.5)
        cap.priority = .defaultHigh
        cap.isActive = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: TalkViewController, _: UITraitCollection) in
            self.updateFonts(); self.resizeInput()
        }
        if !store.dryRun { commands = UserDefaults.standard.stringArray(forKey: commandsKey) ?? [] }
        NotificationCenter.default.addObserver(self, selector: #selector(evidenceAction(_:)), name: TalkEvidence.notification, object: nil)
        // "画像を貼り付け" is greyed while the board holds no picture; the board
        // changes when this app copies and, more often, while it is in the
        // background. Both are heard so the menu is right when it opens.
        NotificationCenter.default.addObserver(self, selector: #selector(pasteboardChanged), name: UIPasteboard.changedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pasteboardChanged), name: UIApplication.didBecomeActiveNotification, object: nil)
        observeStore()
    }
    @objc private func pasteboardChanged() { if isViewLoaded { rebuildMenu() } }
    /// The `+` menu as built, for tests that check which entries are offered.
    var attachMenuForTesting: UIMenu? { attach.menu }
    private func observeStore() {
        withObservationTracking {
            updateComposer()
            // Reading it here is what subscribes this controller to it.
            _ = store.revision
            _ = store.followingNewest
            _ = store.loadingOlder
            _ = store.olderRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStore()
                if self.seenLoadingOlder != self.store.loadingOlder {
                    self.seenLoadingOlder = self.store.loadingOlder
                    if self.store.loadingOlder { self.rememberGapToEnd() }
                }
                if self.seenOlderRevision != self.store.olderRevision {
                    self.seenOlderRevision = self.store.olderRevision
                    self.restoreGapToEnd()
                }
                self.keepOnNewest()
            }
        }
    }
    // Older lines arrive above the reader, so the scroll view grows upward and
    // the offset they were sitting at now points somewhere else: the room jumped
    // to the end and the lines they asked for were never shown (2026-09-20,
    // 「さらに読む、押しても、真下に連れてかれ」). What stays the same across a
    // prepend is the distance to the end, so that is what is kept.
    private func rememberGapToEnd() {
        guard let scroll = transcriptScroll else { return }
        gapToEnd = scroll.contentSize.height - scroll.contentOffset.y
    }
    /// Consumed as it is applied, and applied again over the next few frames:
    /// the rows land before SwiftUI has laid them out, so the first answer to
    /// contentSize is not the one that counts.
    private func restoreGapToEnd() {
        guard let gap = gapToEnd else { return }
        gapToEnd = nil
        keepGapToEnd(gap, repeats: 4)
    }
    private func keepGapToEnd(_ gap: CGFloat, repeats: Int) {
        guard let scroll = transcriptScroll, scroll.contentSize.height > 0 else { return }
        let target = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - gap)
        if abs(scroll.contentOffset.y - target) > 1 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
        }
        guard repeats > 0 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.keepGapToEnd(gap, repeats: repeats - 1)
        }
    }
    // The transcript is a SwiftUI ScrollView hosted here. Neither
    // ScrollViewProxy.scrollTo nor ScrollPosition moved it (measured: asked four
    // times, still 4,000 points from the end), so the scroll view is moved
    // directly. The room lands on its newest line and stays there until the
    // reader goes up; layout of markdown and tables settles a few frames late,
    // so the offset is set again as it does.
    private var transcriptScroll: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return isViewLoaded ? find(host.view) : nil
    }
    func keepOnNewest(repeats: Int = 3) {
        guard store.followingNewest else { return }
        stickToBottom()
        guard repeats > 0 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.keepOnNewest(repeats: repeats - 1)
        }
    }
    private func stickToBottom() {
        guard store.freshStart == nil, store.followingNewest,
              let scroll = transcriptScroll, scroll.bounds.height > 0 else { return }
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        let target = max(-scroll.adjustedContentInset.top, bottom)
        guard abs(scroll.contentOffset.y - target) > 1 else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if TalkLaunch.evidenceFlag("-PocketEvidenceKeyboard") { input.becomeFirstResponder() }
    }
    private func buildComposer() {
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.backgroundColor = .secondarySystemBackground
        composer.layer.cornerRadius = 26
        composer.accessibilityIdentifier = "talk.composer"
        view.addSubview(composer)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.backgroundColor = .clear
        input.textColor = .label
        input.adjustsFontForContentSizeCategory = true
        input.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        input.textContainer.lineFragmentPadding = 0
        input.isScrollEnabled = false
        input.delegate = self
        input.accessibilityIdentifier = "talk.input"
        input.accessibilityLabel = Copy.composePlaceholder
        input.text = store.draft
        input.onPasteImage = { [weak self] image in self?.adopt(image) }
        input.onPasteVideo = { [weak self] provider in self?.adoptVideo(provider) }
        addChild(videoHost)
        videoHost.view.backgroundColor = .clear
        videoHost.sizingOptions = .intrinsicContentSize
        videoHost.view.translatesAutoresizingMaskIntoConstraints = false
        videoHeight = videoHost.view.heightAnchor.constraint(equalToConstant: 44)
        videoHeight.isActive = true
        videoHost.didMove(toParent: self)
        attachmentStrip.axis = .vertical
        attachmentStrip.spacing = 6
        attachmentStrip.translatesAutoresizingMaskIntoConstraints = false
        attachmentStrip.accessibilityIdentifier = "talk.attachments"
        placeholder.text = Copy.composePlaceholder
        placeholder.textColor = .placeholderText
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        selectionStrip.axis = .vertical; selectionStrip.spacing = 3
        selectionStrip.translatesAutoresizingMaskIntoConstraints = false
        selectionHeight = selectionStrip.heightAnchor.constraint(equalToConstant: 0)
        selectionHeight.isActive = true
        for (button, symbol, label, id) in [(attach, "plus", "添付とクイックコマンド", "talk.attach"),
                                          (slashButton, "", TalkSelectCopy.slash, "talk.slash"),
                                          (send, "arrow.up", "送信", "talk.send")] {
            var configuration = UIButton.Configuration.plain()
            configuration.image = symbol.isEmpty ? nil : UIImage(systemName: symbol)
            if button === slashButton { configuration.title = "/" }
            configuration.baseForegroundColor = .label
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            if button === slashButton {
                configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var result = attributes; result.font = .systemFont(ofSize: 22); return result
                }
            }
            configuration.background.backgroundColor = button === attach ? .clear : .tertiarySystemFill
            configuration.background.cornerRadius = 22
            button.configuration = configuration
            button.accessibilityLabel = label; button.accessibilityIdentifier = id
            button.translatesAutoresizingMaskIntoConstraints = false
            let width = button.widthAnchor.constraint(equalToConstant: 44)
            width.isActive = true
            if button === send { sendWidth = width }
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        send.addTarget(self, action: #selector(submit), for: .touchUpInside)
        slashButton.addTarget(self, action: #selector(showSlash), for: .touchUpInside)
        attach.showsMenuAsPrimaryAction = true
        rebuildMenu()
        for child in [selectionStrip, attachmentStrip, input, placeholder, attach, slashButton, send] { composer.addSubview(child) }
        textHeight = input.heightAnchor.constraint(equalToConstant: 36)
        // The strip is 0 points tall while empty, so the input sits where it always did.
        inputTop = input.topAnchor.constraint(equalTo: attachmentStrip.bottomAnchor)
        stripHeight = attachmentStrip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight.isActive = true
        NSLayoutConstraint.activate([
            selectionStrip.topAnchor.constraint(equalTo: composer.topAnchor, constant: 8),
            selectionStrip.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 8),
            selectionStrip.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -8),
            attachmentStrip.topAnchor.constraint(equalTo: selectionStrip.bottomAnchor),
            attachmentStrip.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            attachmentStrip.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            inputTop,
            input.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -8),
            input.leadingAnchor.constraint(equalTo: slashButton.trailingAnchor, constant: 4),
            input.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -4), textHeight,
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 6),
            attach.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 4),
            attach.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -4),
            slashButton.leadingAnchor.constraint(equalTo: attach.trailingAnchor),
            slashButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -4),
            send.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -4),
            send.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -4)
        ])
        updateFonts()
    }
    private func updateFonts() {
        // Same 15 pt step as the transcript and the situation previews.
        input.font = .preferredFont(forTextStyle: .subheadline)
        placeholder.font = .preferredFont(forTextStyle: .subheadline)
    }
    func updateComposer() {
        guard isViewLoaded else { return }
        placeholder.isHidden = !input.text.isEmpty
        if seenDeliveryRevision != store.deliveryRevision {
            seenDeliveryRevision = store.deliveryRevision
            hasPrompts = !store.prompts.load().isEmpty
        }
        if seenDraftRevision != store.draftRevision {
            seenDraftRevision = store.draftRevision
            if input.markedTextRange != nil { deferredDraft = store.draft }
            else { input.text = store.draft }
        }
        if seenAttachmentRevision != store.attachmentRevision || seenVideoRevision != store.videos.revision {
            seenAttachmentRevision = store.attachmentRevision
            seenVideoRevision = store.videos.revision
            rebuildAttachmentStrip()
        }
        let hasText = !TalkSendText.normalize(input.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A nonempty draft still uses the existing ordered send/reservation path.
        let stop = !hasText && store.snapshot?.status == "working" && !store.freshAwaitingInput
        // Windows is where the message would go; while it cannot be reached the draft stays and send waits.
        let winBlocked = ConnectionMonitor.shared.blocksWinSend
        send.isEnabled = !winBlocked && (stop ? store.canInterrupt : store.canCompose && TalkSendText.valid(TalkSendText.normalize(input.text)))
        attach.isEnabled = !store.attaching && !store.videos.busy && !store.sending && !store.questionOpen
        let armed = store.clearArmed
        send.configuration?.image = armed ? nil : UIImage(systemName: stop ? "stop.fill" : "arrow.up")
        send.configuration?.title = armed ? TalkSelectCopy.confirmClear : nil
        send.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = .preferredFont(forTextStyle: .caption1); return result
        }
        sendWidth.constant = armed ? 154 : 44
        send.accessibilityLabel = armed ? TalkSelectCopy.confirmClear : stop ? TalkSelectCopy.interrupt : "送信"
        send.accessibilityHint = armed ? TalkSelectCopy.clearHint : nil
        slashButton.isEnabled = !store.attaching && !store.videos.busy
        // While the seat is asking, say so where the message would have gone.
        // VoiceOver reads the text view, not this label, so both carry it.
        let currentAgent = store.snapshot?.agent == "codex" ? "codex" : "claude"
        if store.slash.agent != currentAgent { store.slash.agent = currentAgent }
        let entry = store.slash.entry(for: input.text)
        placeholder.text = store.questionOpen ? TalkSelectCopy.selectionFirst : winBlocked ? ConnectionCopy.sendWhenWin : entry?.category == .arg ? entry?.argHint ?? Copy.composePlaceholder : Copy.composePlaceholder
        input.accessibilityLabel = placeholder.text
        placeholder.isHidden = !input.text.isEmpty
        updateSelectionStrip()
        updateSendColor()
        resizeInput()
        rebuildMenu()
    }
    @objc private func showSlash() {
        guard presentedViewController == nil else { return }
        TalkSelectMetrics.shared.slashBegan()
        let sheet = UIHostingController(rootView: TalkSlashPalette(catalog: store.slash, select: { [weak self] entry in
            guard let self else { return }
            self.insertSlash(entry)
            self.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { self.input.becomeFirstResponder() }
        }, close: { [weak self] in self?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) }))
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        // The medium sheet must show its first cached row inside 150 ms.
        present(sheet, animated: false)
        Task { await store.slash.refresh(session: store.client.session) }
    }
    private func insertSlash(_ entry: TalkSlashEntry) {
        guard entry.selectable else { return }
        input.unmarkText()
        store.saveDraft(input.text ?? "")
        store.insertSlash(entry)
        input.text = store.draft
        input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
        textViewDidChange(input)
        input.becomeFirstResponder()
    }
    private func updateSelectionStrip() {
        let entries = store.questionOpen ? [] : store.slash.inline(input.text ?? "")
        let hint = store.questionOpen ? TalkSelectCopy.selectionFirst : store.slash.entry(for: input.text ?? "").flatMap { $0.category == .arg ? $0.argHint : nil }
        let signature = (hint ?? "") + entries.map { $0.id + $0.call + $0.line }.joined(separator: "|")
        guard signature != selectionSignature else { return }
        selectionSignature = signature
        for child in selectionStrip.arrangedSubviews { selectionStrip.removeArrangedSubview(child); child.removeFromSuperview() }
        if let hint {
            let label = UILabel()
            label.text = hint; label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel; label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.accessibilityIdentifier = "talk.selectionNotice"
            selectionStrip.addArrangedSubview(label)
        }
        for entry in entries {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = entry.call; config.subtitle = entry.line
            config.titleAlignment = .leading; config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes; result.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .medium)); return result
            }
            config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes; result.font = .preferredFont(forTextStyle: .caption2); return result
            }
            button.configuration = config
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "talk.slash.inline.\(entry.id)"
            button.accessibilityLabel = entry.call + "。" + entry.line
            button.addAction(UIAction { [weak self] _ in self?.insertSlash(entry) }, for: .touchUpInside)
            selectionStrip.addArrangedSubview(button)
        }
        selectionHeight.isActive = selectionStrip.arrangedSubviews.isEmpty
    }
    @objc private func evidenceAction(_ notification: Notification) {
        guard store.dryRun, store.sessionID == TalkLaunch.argument("-PocketEvidenceTalk"), let action = notification.object as? String else { return }
        switch action {
        case "send":
            input.text = "乾いた送信の確認。ネイティブの入力から送達表示まで。"
            textViewDidChange(input); submit()
        case "keyboard": if store.dryRun { input.becomeFirstResponder() }
        case "lines":
            guard store.dryRun else { return }
            input.text = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7"
            textViewDidChange(input); input.becomeFirstResponder()
        case "cancel":
            if store.dryRun, let id = store.reservations.first?.id { Task { await store.cancelReservation(id) } }
        case "retry":
            if store.dryRun, let message = store.localMessages.last, message.retryAllowed {
                Task { await store.submit(message.text, retryID: message.id) }
            }
        default: break
        }
        logger.info("native_evidence_action action=\(action, privacy: .public) session=\(self.store.sessionID, privacy: .public)")
    }
    @objc private func submit() {
        guard send.isEnabled else { return }
        if (input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await store.interrupt(); updateComposer() }
            return
        }
        store.submitted(at: .now)
        input.unmarkText()
        let text = input.text ?? ""
        store.saveDraft(text)
        motion.talkSend()
        Task { await store.submit(text); updateComposer() }
    }
    /// At most this many pictures get a row of their own; the rest are counted.
    /// The strip sits above the input inside the composer, and the composer eats
    /// the room from the bottom up, so its height has to be bounded by
    /// construction rather than by how many pictures someone attached.
    static let attachmentRowsShown = 3
    private func rebuildAttachmentStrip() {
        for row in attachmentStrip.arrangedSubviews { attachmentStrip.removeArrangedSubview(row); row.removeFromSuperview() }
        for record in store.attachments.prefix(Self.attachmentRowsShown) {
            attachmentStrip.addArrangedSubview(attachmentRow(record))
        }
        let hidden = store.attachments.count - Self.attachmentRowsShown
        if hidden > 0 {
            let more = UILabel()
            more.text = "ほか \(hidden) 枚"
            more.font = .preferredFont(forTextStyle: .footnote)
            more.adjustsFontForContentSizeCategory = true
            more.textColor = .secondaryLabel
            more.accessibilityIdentifier = "talk.attachment.more"
            attachmentStrip.addArrangedSubview(more)
        }
        if store.videos.isVisible {
            videoHeight.constant = (store.videos.hasPreview ? 150 : 0) + (store.videos.busy ? 38 : 0)
                + (store.videos.failure != nil ? 44 : 0)
            attachmentStrip.addArrangedSubview(videoHost.view)
        }
        inputTop.constant = attachmentStrip.arrangedSubviews.isEmpty ? 0 : 6
        // An empty stack view has no intrinsic height, and the strip's own top
        // and bottom are both pinned inside the composer: with no rows the
        // height is whatever Auto Layout feels like, and on 2026-09-19 it came
        // out at some 650 points -- the composer filled the screen, the room was
        // squeezed to nothing, and the phone showed a grey card with an input at
        // the bottom of it. Empty means zero, said out loud.
        stripHeight.isActive = attachmentStrip.arrangedSubviews.isEmpty
    }
    /// One attached picture: its small copy, its name, and the way to take it
    /// off. Taking it off removes the path line from the draft as well.
    private func attachmentRow(_ record: TalkStore.Attachment) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal; row.spacing = 8; row.alignment = .center
        row.accessibilityIdentifier = "talk.attachment"
        let thumb = UIImageView(image: record.thumbnail.flatMap(UIImage.init(data:)))
        thumb.contentMode = .scaleAspectFill; thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 8; thumb.backgroundColor = .tertiarySystemFill
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 44).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 44).isActive = true
        thumb.isAccessibilityElement = true
        thumb.accessibilityLabel = "添付した画像"
        thumb.accessibilityIdentifier = "talk.attachment.thumb"
        let name = UILabel()
        name.text = FileOpen.name(record.path)
        name.font = .preferredFont(forTextStyle: .footnote); name.adjustsFontForContentSizeCategory = true
        name.textColor = .secondaryLabel; name.lineBreakMode = .byTruncatingHead
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString("外す", attributes: AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .footnote)]))
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        let remove = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.store.removeAttachment(record.id)
            self.updateComposer()
        })
        remove.accessibilityLabel = "添付を外す"
        remove.accessibilityIdentifier = "talk.attachment.remove"
        remove.setContentHuggingPriority(.required, for: .horizontal)
        for child in [thumb, name, remove] { row.addArrangedSubview(child) }
        // As tall as its thumbnail. Without this the row took whatever height it
        // could get and three of them filled a third of the screen.
        let height = row.heightAnchor.constraint(equalToConstant: 44)
        height.priority = .defaultHigh
        height.isActive = true
        return row
    }
    /// A picture from the pasteboard, or from the picker, on its way to the
    /// same reduction and upload the photo picker has always used.
    private func adopt(_ image: UIImage) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = TalkAttachment.jpeg(image)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data { await self.store.attach(data) } else { self.store.attachmentRejected() }
                self.updateComposer()
            }
        }
    }
    /// The menu's way in: the words go in at the cursor, the picture is attached.
    private func pasteImage(preferVideo: Bool = false) {
        let paste = TalkPaste.take(preferVideo: preferVideo)
        if let text = paste.text { input.insertPastedText(text) }
        if let image = paste.image { adopt(image) }
        if let video = paste.video { adoptVideo(video) }
    }
    private func adoptVideo(_ provider: NSItemProvider) {
        Task { await store.attachVideo(VideoSelection(provider: provider)); updateComposer() }
    }
    private func pickVideo() {
        pickingVideo = true
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos; config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config); picker.delegate = self
        present(picker, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    private func pickImage() {
        pickingVideo = false
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images; config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config); picker.delegate = self
        present(picker, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        guard let provider = results.first?.itemProvider else { return }
        if pickingVideo {
            adoptVideo(provider)
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] value, _ in
            // The same reduction the web app applies before its upload: the
            // server accepts a body of 6 MB, base64 included, and a phone photo
            // sent at full size came back 413 on 2026-09-15.
            let data = (value as? UIImage).flatMap(TalkAttachment.jpeg)
            Task { @MainActor in
                guard let self else { return }
                if let data { await self.store.attach(data) } else { self.store.attachmentRejected() }
                self.updateComposer()
            }
        }
    }
    private func showPrompts() {
        let sheet = UIHostingController(rootView: TalkPromptHistoryView(store: store.prompts) { [weak self] text in
            self?.insertCommand(text)
        })
        sheet.view.accessibilityIdentifier = "talk.prompts"
        present(sheet, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    private func insertCompact() {
        if let entry = store.slash.entry(for: "/compact") { store.slash.remember(entry) }
        insertCommand("/compact")
    }
    private func insertCommand(_ text: String) {
        input.text = input.text.isEmpty ? text : input.text + "\n" + text
        textViewDidChange(input); input.becomeFirstResponder()
    }
    private func persistCommands() {
        if !store.dryRun { UserDefaults.standard.set(commands, forKey: commandsKey) }
        rebuildMenu()
    }
    private func rebuildMenu() {
        var entries: [UIMenuElement] = [
            UIAction(title: "写真を添付", image: UIImage(systemName: "photo"), attributes: store.canCompose ? [] : .disabled) { [weak self] _ in self?.pickImage() },
            UIAction(title: "動画を選ぶ", image: UIImage(systemName: "video"), attributes: store.canCompose ? [] : .disabled) { [weak self] _ in self?.pickVideo() },
            UIAction(title: "動画を貼り付け", image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: store.canCompose && TalkPaste.canPasteVideo() ? [] : .disabled) { [weak self] _ in self?.pasteImage(preferVideo: true) },
            // Only metadata is asked here: reading the board itself would show
            // the "pasted from" banner every time this menu is built.
            UIAction(title: "画像を貼り付け", image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: store.canCompose && TalkPaste.canPasteImage() ? [] : .disabled) { [weak self] _ in self?.pasteImage() },
            UIAction(title: "/compact", image: UIImage(systemName: "text.bubble")) { [weak self] _ in self?.insertCompact() },
            // Every line the seat took is already recorded; the entry only
            // appears once there is something to show.
            UIAction(title: "よく使う文面", image: UIImage(systemName: "clock.arrow.circlepath"),
                     attributes: hasPrompts ? [] : .disabled) { [weak self] _ in self?.showPrompts() }
        ]
        for command in commands {
            let label = String(command.replacingOccurrences(of: "\n", with: " ").prefix(24))
            entries.append(UIMenu(title: label, children: [
                UIAction(title: "挿入") { [weak self] _ in self?.insertCommand(command) },
                UIAction(title: "登録を解除", attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    let alert = UIAlertController(title: "このクイックコマンドの登録を解除しますか？", message: label, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "戻る", style: .cancel))
                    alert.addAction(UIAlertAction(title: "解除", style: .destructive) { [weak self] _ in
                        self?.commands.removeAll { $0 == command }; self?.persistCommands()
                    })
                    self.present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
                }
            ]))
        }
        let empty = input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        entries.append(UIAction(title: commands.count >= 12 ? "登録は12件まで" : "入力をクイックコマンドに登録",
            image: UIImage(systemName: "bookmark"), attributes: empty || commands.count >= 12 ? .disabled : []) { [weak self] _ in
                guard let self, !self.commands.contains(self.input.text) else { return }
                self.commands.append(self.input.text); self.persistCommands()
            })
        attach.menu = UIMenu(children: entries)
    }
    func textViewDidChange(_ textView: UITextView) {
        // Defer programmatic restoration until Japanese marked text is committed.
        if input.markedTextRange == nil, let deferredDraft {
            self.deferredDraft = nil
            input.text = deferredDraft.isEmpty ? input.text : deferredDraft + (input.text.isEmpty ? "" : "\n" + input.text)
        }
        store.saveDraft(textView.text)
        placeholder.isHidden = !textView.text.isEmpty
        updateComposer()
    }
    private func updateSendColor() {
        let hasText = !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.configuration?.background.backgroundColor = hasText ? UIColor(named: "Accent") : .tertiarySystemFill
        send.configuration?.baseForegroundColor = hasText ? .white : .secondaryLabel
    }
    private func resizeInput() {
        guard input.bounds.width > 0, let font = input.font else { return }
        let minimum = max(36, ceil(font.lineHeight) + 12)
        let maximum = ceil(font.lineHeight * 6) + 12
        let fitting = input.sizeThatFits(CGSize(width: input.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(maximum, max(minimum, ceil(fitting)))
        if abs(textHeight.constant - height) > 0.5 { textHeight.constant = height }
        input.isScrollEnabled = fitting > maximum
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        stickToBottom()
        resizeInput()
        let guide = view.keyboardLayoutGuide.layoutFrame
        let value = "card=\(composer.frame) guide=\(guide) gap=\(guide.minY - composer.frame.maxY) body=\(host.view.frame)"
        if value != lastGeometry {
            lastGeometry = value; logger.info("\(value, privacy: .public)")
        }
    }
}
