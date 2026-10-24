import SwiftUI
import WebKit

struct WebScreen: View {
    let url: URL
    /// What the bar says. The navigation bar is hidden here, so a title set
    /// on the screen from outside would not show.
    var title = ""
    /// Given for a sheet: 閉じる on the right and no back chevron.
    var close: (() -> Void)?
    @State private var loading = true
    @State private var error: String?
    @State private var chrome = ReaderChrome()
    @Environment(\.dismiss) private var dismiss
    private var back: (() -> Void)? {
        if close != nil { return nil }
        return { dismiss() }
    }
    var body: some View {
        WebReader(url: url, loading: $loading, error: $error, chrome: chrome)
            // The retained Web surfaces are readers.
            .accessibilityIdentifier("web.screen")
            .readerChrome(chrome) {
                ReaderBar(title: title, back: back) {
                    if let close {
                        Button("閉じる", action: close)
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: ReaderBar<EmptyView>.height)
                            .padding(.horizontal, 8)
                    }
                }
            } notice: {
                if loading { ProgressView().padding(8).background(.regularMaterial, in: Capsule()) }
                if let error { Text(error).font(.callout).padding().background(.regularMaterial) }
            }
    }
}

struct WebReader: UIViewControllerRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var error: String?
    var chrome: ReaderChrome?

    func makeUIViewController(context: Context) -> LegacyWebViewController {
        LegacyWebViewController(url: url, chrome: chrome) { busy, message in
            loading = busy
            error = message
        }
    }
    func updateUIViewController(_ controller: LegacyWebViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: LegacyWebViewController, coordinator: ()) {
        controller.shutdown()
    }
}
