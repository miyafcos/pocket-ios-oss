import SwiftUI

struct TalkPickerCard: View {
    let picker: TalkPicker
    let busy: Bool
    let key: (String) -> Void
    let row: (Int) -> Void
    let painted: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(picker.title ?? "").font(.headline).bold()
            Text(TalkSelectCopy.openedOnPC).font(.caption).foregroundStyle(.secondary)
            if !(picker.notes ?? []).isEmpty {
                Text((picker.notes ?? []).joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(Array(picker.visibleRows.enumerated()), id: \.offset) { _, item in
                Button { if let number = item.number { row(number) } } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.cursor == true ? "›" : " ").fontWeight(.bold)
                        if item.checked == true { Image(systemName: "checkmark").fontWeight(.semibold) }
                        Text(item.text ?? "").font(.subheadline).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(item.cursor == true ? Color.accentColor.opacity(0.16) : Color(uiColor: .tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(busy || picker.fingerprint?.isEmpty != false)
                    .accessibilityIdentifier("talk.picker.row.\(item.number ?? 0)")
                    .accessibilityLabel(TalkSelectCopy.rowVoice(item.number ?? 0, text: item.text ?? "",
                                                               cursor: item.cursor == true, checked: item.checked == true))
                    .accessibilityAddTraits(item.cursor == true ? .isSelected : [])
            }
            if let more = picker.more {
                HStack {
                    VStack(alignment: .leading) {
                        if more.above == true { Text(TalkSelectCopy.above) }
                        if more.below == true { Text(TalkSelectCopy.below(more.text ?? "")) }
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    arrow("up"); arrow("down")
                }
            }
            if let adjust = picker.adjust {
                HStack {
                    Text(adjust.text ?? "").font(.subheadline)
                    Spacer(minLength: 0)
                    if (adjust.keys ?? []).contains("left") { arrow("left") }
                    if (adjust.keys ?? []).contains("right") { arrow("right") }
                }
            }
            if !(picker.body ?? []).isEmpty {
                // Fit the whole terminal block at one size so its columns align.
                ViewThatFits(in: .horizontal) {
                    ForEach([14.0, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4], id: \.self) { size in
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array((picker.body ?? []).enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line).font(.system(size: CGFloat(size), design: .monospaced))
                                    .fixedSize(horizontal: true, vertical: true)
                            }
                        }.fixedSize(horizontal: true, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("talk.picker.body")
            }
            ForEach(Array((picker.actions ?? []).enumerated()), id: \.offset) { _, action in
                VStack(alignment: .leading, spacing: 3) {
                    if action.prominent {
                        actionButton(action).buttonStyle(.borderedProminent)
                    } else {
                        actionButton(action).buttonStyle(.bordered)
                    }
                    if let note = action.note {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("talk.picker.persistNote")
                    }
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("talk.picker")
            .background(TalkSelectPaintProbe(painted: painted).allowsHitTesting(false).accessibilityHidden(true))
    }
    private func actionButton(_ action: TalkPicker.Action) -> some View {
        Button(action.title) { if let value = action.key { key(value) } }
            .disabled(busy || !picker.offers(action.key ?? "") || picker.fingerprint?.isEmpty != false)
            .accessibilityIdentifier("talk.picker.key.\(action.key ?? "")")
            .accessibilityLabel(action.voice)
    }
    private func arrow(_ value: String) -> some View {
        Button(TalkSelectCopy.keyName(value)) { key(value) }
            .buttonStyle(.bordered).frame(minWidth: 44, minHeight: 44)
            .disabled(busy || !picker.offers(value) || picker.fingerprint?.isEmpty != false)
            .accessibilityIdentifier("talk.picker.arrow.\(value)")
            .accessibilityLabel(TalkSelectCopy.voice(TalkSelectCopy.keyMeaning(value), key: value, persists: false))
    }
}
