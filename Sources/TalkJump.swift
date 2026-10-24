import SwiftUI

// CC Pocket lists the person's own messages so a long room can be jumped through
// (rewind_message_list_sheet.dart). Theirs exists to pick a rewind point, which
// we do not have; ours is only for reading, so the agent's own headings are in
// the list too — our markdown already knows where they are.
enum TalkJumpRequest {
    static let notification = Notification.Name("PocketTalkJump")
}
struct TalkJumpEntry: Identifiable {
    enum Kind { case spoken, heading(Int) }
    let id: String
    let kind: Kind
    let text: String
    let at: Date?
}
enum TalkJump {
    static let preview = 60
    static func entries(_ rows: [TalkTimeline.Row]) -> [TalkJumpEntry] {
        var result: [TalkJumpEntry] = []
        for row in rows {
            guard case .event(let event) = row.kind else { continue }
            guard TalkMachineMessage.kind(event.text) == nil else { continue }
            if event.role == "user" {
                let text = line(event.text)
                guard !text.isEmpty else { continue }
                result.append(TalkJumpEntry(id: row.id, kind: .spoken, text: text, at: event.date))
            } else {
                for block in TalkMarkdown.parse(event.text) {
                    guard case .heading(let level, let text) = block, level <= 3 else { continue }
                    let value = line(text)
                    guard !value.isEmpty else { continue }
                    result.append(TalkJumpEntry(id: row.id, kind: .heading(level), text: value, at: event.date))
                }
            }
        }
        return result
    }
    static func line(_ raw: String) -> String {
        let value = SessionPreview.mask(raw).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(String.UnicodeScalarView(value.unicodeScalars.prefix(preview)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
struct TalkJumpView: View {
    let entries: [TalkJumpEntry]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("目印がありません", systemImage: "list.bullet.indent",
                                           description: Text("送った文面と見出しがここに並びます。"))
                } else {
                    List(entries) { entry in
                        Button {
                            onSelect(entry.id)
                            dismiss()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                mark(entry)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text).font(PocketType.text).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if let at = entry.at {
                                        Text(at.formatted(date: .omitted, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: indent(entry) + PocketLayout.leading,
                                                  bottom: 8, trailing: PocketLayout.leading))
                        .accessibilityIdentifier("jump.row")
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("目印")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }.accessibilityIdentifier("jump.close")
                }
            }
        }
    }
    @ViewBuilder private func mark(_ entry: TalkJumpEntry) -> some View {
        switch entry.kind {
        case .spoken:
            Image(systemName: "person.fill").font(.caption).foregroundStyle(Color("Accent"))
                .accessibilityLabel("あなたの発言")
        case .heading:
            Image(systemName: "number").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("見出し")
        }
    }
    private func indent(_ entry: TalkJumpEntry) -> CGFloat {
        if case .heading(let level) = entry.kind { return CGFloat(level - 1) * 14 }
        return 0
    }
}
