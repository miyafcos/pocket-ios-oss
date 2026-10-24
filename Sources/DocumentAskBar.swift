import SwiftUI

struct DocumentAskBar: View {
    @Bindable var model: DocumentAsk
    @Bindable var pocket: PocketStore
    let close: () -> Void
    let sent: (String, Destination) -> Void
    @State private var referenceExpanded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error ?? model.validationError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .accessibilityIdentifier("doc.ask.error")
            }
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Menu {
                        if !model.recentTargets.isEmpty {
                            Section(Copy.documentAskRecent) {
                                ForEach(model.recentTargets, id: \.self) { target in
                                    Button(target.title(in: pocket.overview)) { model.select(target) }
                                }
                            }
                        }
                        Button(Copy.documentAskHarness) { model.select(.harness) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(Copy.documentAskDestination).foregroundStyle(.secondary)
                            Text(model.draft.target.title(in: pocket.overview)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color("Accent").opacity(0.10), in: Capsule())
                    }
                    .accessibilityIdentifier("doc.ask.target")
                    .accessibilityLabel(Copy.documentAskDestination)
                    .accessibilityValue(model.draft.target.title(in: pocket.overview))
                    .disabled(model.sending)
                    Spacer(minLength: 0)
                    Button {
                        focused = false
                        close()
                    } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.documentAskClose)
                    .accessibilityIdentifier("doc.ask.close")
                    .disabled(model.sending)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(Copy.documentAskPlaceholder,
                              text: Binding(get: { model.draft.text }, set: { model.setText($0) }),
                              axis: .vertical)
                        .lineLimit(1...4).font(.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 22))
                        .focused($focused)
                        .accessibilityIdentifier("doc.ask.input")
                        .accessibilityLabel(Copy.documentAskPlaceholder)
                        .disabled(model.sending)
                    Button {
                        let client = DocumentAskClient(base: model.base)
                        let name = model.draft.target.title(in: pocket.overview)
                        Task {
                            var destination = model.draft.target.destination
                            if let notice = await model.send(targetName: name, using: { text, target in
                                let receipt = try await client.sendReceipt(text, to: target)
                                destination = receipt.destination
                                return receipt.result
                            }) {
                                focused = false
                                sent(notice, destination)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up").font(.body)
                        .foregroundStyle(Color(uiColor: .label))
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                        .opacity(model.canSend || model.sending ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canSend)
                    .accessibilityLabel(Copy.documentAskSend)
                    .accessibilityIdentifier("doc.ask.send")
                }
                HStack(spacing: 6) {
                    if TalkLaunch.dryRun {
                        Text("DRY").font(.caption2.monospaced().bold())
                    }
                    Button { referenceExpanded.toggle() } label: {
                        HStack(spacing: 4) {
                            Text("\(Copy.documentAskReference) 成果物「\(model.reference.title)」")
                                .lineLimit(1)
                            Image(systemName: referenceExpanded ? "chevron.down" : "chevron.right")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("doc.ask.reference")
                    .accessibilityValue(referenceExpanded ? "展開" : "折りたたみ")
                }
                .font(.caption).foregroundStyle(.secondary)
                if referenceExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.reference.path).accessibilityIdentifier("doc.ask.reference.path")
                        Text(model.reference.url.absoluteString).accessibilityIdentifier("doc.ask.reference.url")
                    }
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .task { await pocket.refreshOverview() }
    }
}
