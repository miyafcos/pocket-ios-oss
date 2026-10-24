import SwiftUI

// The sheet behind the composer's よく使う文面 entry. Shape borrowed from CC
// Pocket (MIT, K9i-0/ccpocket @ a505794) features/prompt_history/: no search
// box, one button cycling the order, a use count on the right, a star, and a
// swipe to delete that a favourite refuses.
struct TalkPromptHistoryView: View {
    let store: TalkPromptStore
    let onSelect: (String) -> Void
    @State private var prompts: [TalkPrompt] = []
    @State private var sort: TalkPromptSort = .frequent
    @Environment(\.dismiss) private var dismiss
    private var sortKey: String { "talk.native.promptSort:\(store.base)" }

    var body: some View {
        NavigationStack {
            Group {
                if prompts.isEmpty {
                    ContentUnavailableView("送った文面がまだありません", systemImage: "text.badge.plus",
                                           description: Text("送信した文面がここに貯まります。"))
                } else {
                    List {
                        ForEach(TalkPromptStore.sorted(prompts, by: sort)) { prompt in
                            row(prompt)
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("よく使う文面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The name of the order has to be readable, not only its icon;
                    // a toolbar Label keeps only the glyph.
                    Button { cycle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: sort.symbol)
                            Text(sort.title)
                        }.font(.footnote)
                    }
                        .accessibilityIdentifier("prompts.sort")
                        .accessibilityValue(sort.title)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.accessibilityIdentifier("prompts.close")
                }
            }
        }
        .task {
            prompts = store.load()
            if let saved = store.defaults.string(forKey: sortKey),
               let value = TalkPromptSort(rawValue: saved) { sort = value }
        }
    }
    private func cycle() {
        sort = sort.next
        // The same defaults as the list, so a DRY launch keeps nothing.
        store.defaults.set(sort.rawValue, forKey: sortKey)
    }
    @ViewBuilder private func row(_ prompt: TalkPrompt) -> some View {
        Button {
            onSelect(prompt.text)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TalkPromptStore.line(prompt))
                    .font(PocketType.text).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if prompt.useCount > 1 {
                    Text("×\(prompt.useCount)").font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit().accessibilityLabel("\(prompt.useCount) 回")
                }
                Button {
                    prompts = store.toggleFavorite(prompt.id)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: prompt.favorite ? "star.fill" : "star")
                        .foregroundStyle(prompt.favorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(prompt.favorite ? "お気に入りを解除" : "お気に入りにする")
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("prompts.row")
        .swipeActions(edge: .trailing) {
            if !prompt.favorite {
                Button("削除", role: .destructive) { prompts = store.remove(prompt.id) }
            }
        }
    }
}
