import SwiftUI

extension View {
    func documentAsk(_ reference: DocumentAskReference?, originSessionID: String? = nil) -> some View {
        modifier(DocumentAskButton(reference: reference, originSessionID: originSessionID))
    }
    func documentAskFromToolbar(_ reference: DocumentAskReference?, originSessionID: String? = nil, open: Binding<Bool>) -> some View {
        modifier(DocumentAskButton(reference: reference, originSessionID: originSessionID, floating: false, toolbarOpen: open))
    }

}

private struct DocumentAskNotice: Identifiable {
    let id = UUID()
    let text: String
    let destination: Destination
}

/// The button stays outside ReaderChrome. The open bar reserves space below
/// the reader, so the document remains scrollable while an instruction is typed.
private struct DocumentAskButton: ViewModifier {
    let reference: DocumentAskReference?
    let originSessionID: String?
    var floating = true
    var toolbarOpen: Binding<Bool>? = nil
    @Environment(PocketStore.self) private var pocket
    @Environment(\.dismiss) private var dismiss
    @State private var model: DocumentAsk?
    @State private var notice: DocumentAskNotice?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if floating, let reference, model == nil {
                    Button {
                        model = DocumentAsk(reference: reference, base: pocket.base,
                                            originSessionID: originSessionID, recent: pocket.recent)
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color("Accent"), in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("doc.ask")
                    .accessibilityLabel(Copy.documentAsk)
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let model {
                    DocumentAskBar(model: model, pocket: pocket, close: {
                        self.model = nil; toolbarOpen?.wrappedValue = false
                    }, sent: { message, destination in
                        self.model = nil; toolbarOpen?.wrappedValue = false
                        notice = DocumentAskNotice(text: message, destination: destination)
                    })
                }
            }
            .overlay(alignment: .top) {
                if let notice {
                    VStack(spacing: 8) {
                        Text(notice.text).accessibilityIdentifier("doc.ask.notice")
                        Button("トークを開く") {
                            if originSessionID != nil { dismiss() }
                            pocket.navigationPath = [notice.destination]
                            self.notice = nil
                        }
                        .accessibilityIdentifier("doc.ask.openTalk")
                    }
                    .font(.footnote).padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16).padding(.top, 44)
                }
            }
            .onChange(of: reference?.id) {
                // A link in the still-interactive reader can open another document.
                // Its instruction must not inherit the previous document's target.
                model = nil; toolbarOpen?.wrappedValue = false
            }
            .onChange(of: toolbarOpen?.wrappedValue) { _, open in
                if open == true, let reference { model = DocumentAsk(reference: reference, base: pocket.base, originSessionID: originSessionID, recent: pocket.recent) }
                else if open == false { model = nil }
            }
            .task(id: notice?.id) {
                guard notice != nil else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                notice = nil
            }
    }
}
