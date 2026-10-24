import SwiftUI
import VisionKit
import AVFoundation

struct PairingView: View {
    @Bindable var store: PocketStore
    @State private var input = ""
    @State private var tailnet = ""
    @State private var error: String?
    @State private var busy = false
    @State private var scannerOpen = false
    @State private var scannedText: String?
    @State private var cameraMessage: String?
    @State private var confirmation: VerifiedPairing?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Image(systemName: "desktopcomputer")
                        .font(.largeTitle).foregroundStyle(Color("Accent"))
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                    Text("PC とつなぐ").font(.title2).fontWeight(.semibold)
                    Text("PC の mycmux で iPhone 連携を開き、表示された QR を読み取ってください。")
                        .foregroundStyle(.secondary)
                    Button("PC の QR を読む", systemImage: "qrcode.viewfinder") {
                        Task { await openScanner() }
                    }.accessibilityIdentifier("pair.scan")
                    if let cameraMessage { Text(cameraMessage).font(.footnote).foregroundStyle(.secondary) }
                    #if targetEnvironment(simulator)
                    Text("シミュレータではカメラを使えません。手入力で追加してください。")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                }
                Section("手入力") {
                    TextField("PC 名または https:// の URL", text: $input)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit { parse(input) }
                        .accessibilityIdentifier("pair.input")
                    TextField("tailnet 名（PC 名で追加するとき）", text: $tailnet)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).accessibilityIdentifier("pair.tailnet")
                    Text("初めて PC 名で追加するときは、Tailscale の DNS 名にある tailnet 名も入力してください（pc.example.ts.net の example）。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("PC を確認") { parse(input) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                        .accessibilityIdentifier("pair.check")
                    if busy { ProgressView("PC を確認しています") }
                    if let error {
                        Text(error).foregroundStyle(.secondary).accessibilityIdentifier("pair.error")
                    }
                }
                if PairingDryRun.enabled { Text("DRY").font(.caption).accessibilityIdentifier("pair.dry") }
            }
            .navigationTitle("PC を追加").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.machines.machines.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { store.pairingCandidate = nil; store.pairingOpen = false }
                    }
                }
            }
        }
        .tint(Color("Accent"))
        .task(id: store.pairingAttempt) {
            guard let candidate = store.pairingCandidate else { return }
            busy = true; error = nil
            defer { busy = false }
            do {
                let verified = try await VerifiedPairing.fetch(candidate)
                try Task.checkCancellation()
                confirmation = verified
            } catch {
                if !Task.isCancelled { self.error = Self.message(error) }
            }
        }
        .sheet(isPresented: $scannerOpen, onDismiss: {
            if let text = scannedText { scannedText = nil; parse(text) }
        }) {
            Group {
                if PairingDryRun.enabled {
                    Color.clear.accessibilityIdentifier("pair.scanner.fixture")
                } else {
                    QRScanner { text in scannedText = text; scannerOpen = false }
                }
            }
            .overlay(alignment: .topTrailing) {
                Button("閉じる") { scannedText = nil; scannerOpen = false }
                    .accessibilityIdentifier("pair.scanner.cancel").padding()
            }
        }
        .sheet(item: $confirmation, onDismiss: { store.pairingCandidate = nil }) { value in
            NavigationStack {
                List {
                    Section("確認") {
                        LabeledContent("PC 名", value: value.hello.machine.name)
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("pair.confirm.name")
                            .accessibilityLabel("PC 名")
                            .accessibilityValue(value.hello.machine.name)
                        LabeledContent("あなた", value: value.hello.you.login ?? "ログイン名なし")
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("pair.confirm.login")
                            .accessibilityLabel("あなた")
                            .accessibilityValue(value.hello.you.login ?? "ログイン名なし")
                        LabeledContent("許可", value: value.hello.you.allowed ? "許可されています" : "許可されていません")
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("pair.confirm.allowed")
                            .accessibilityLabel("許可")
                            .accessibilityValue(value.hello.you.allowed ? "許可されています" : "許可されていません")
                        Text(value.candidate.base.absoluteString).font(.footnote).foregroundStyle(.secondary)
                        if PocketAPIVersion.recommendsUpdate(value.hello.apiVersion) {
                            Text("ポケットを更新してください").foregroundStyle(.secondary)
                        }
                    }
                    Button("この PC を追加") {
                        store.addMachine(value)
                        confirmation = nil; store.pairingCandidate = nil; store.pairingOpen = false
                    }.accessibilityIdentifier("pair.add")
                }
                .navigationTitle("PC の確認").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { confirmation = nil }.accessibilityIdentifier("pair.cancel")
                    }
                }
            }.tint(Color("Accent"))
        }
    }
    private func parse(_ text: String) {
        do {
            let candidate = try PairingCandidate.parse(text, machines: store.machines.machines, tailnet: tailnet)
            error = nil
            store.beginPairing(candidate)
        } catch { self.error = error.localizedDescription }
    }
    private static func message(_ error: Error) -> String {
        if error is PairingError { return error.localizedDescription }
        if case ClientError.notAllowed = error { return error.localizedDescription }
        return PairingState.failure(error).message ?? error.localizedDescription
    }
    private func openScanner() async {
        if PairingDryRun.enabled { scannedText = nil; scannerOpen = true; return }
        #if targetEnvironment(simulator)
        cameraMessage = "シミュレータではカメラを使えません。手入力で追加してください。"
        #else
        guard DataScannerViewController.isSupported else {
            cameraMessage = "この端末では QR を読み取れません。手入力で追加してください。"; return
        }
        guard await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable else {
            cameraMessage = "カメラを利用できません。設定でカメラを許可するか、手入力で追加してください。"; return
        }
        scannerOpen = true
        #endif
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { context.coordinator.scanned("") }
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        private var delivered = false
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if !delivered, let text = barcode.payloadStringValue {
                    delivered = true; scanned(text); break
                }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            if !delivered { delivered = true; scanned("") }
        }
    }
}

struct ConnectionBanner: View {
    static func shows(pairing: PairingState, connection: ConnectionState) -> Bool {
        pairing != .pcUnreachable || connection != .tailnetWaking
    }
    let store: PocketStore
    @State private var permissionHelp = false
    var body: some View {
        if let message = store.connection.state.message,
           Self.shows(pairing: store.connection.state, connection: ConnectionMonitor.shared.state) {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                switch store.connection.state {
                case .tailscaleOff:
                    Button("Tailscale を開く") {
                        UIApplication.shared.open(URL(string: "tailscale://")!) { opened in
                            if !opened {
                                Task { @MainActor in
                                    UIApplication.shared.open(URL(string: "https://apps.apple.com/app/id1470499037")!)
                                }
                            }
                        }
                    }
                case .pcUnreachable:
                    Button("もう一度") { Task { await store.retryConnection() } }
                case .notAllowed:
                    Button("PC 側の許可手順を見る") { permissionHelp = true }
                default: EmptyView()
                }
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .accessibilityIdentifier("connection.banner")
            .sheet(isPresented: $permissionHelp) {
                NavigationStack {
                    List {
                        Text("PC の mycmux で設定 → iPhone → 許可するユーザーを開き、この iPhone の Tailscale ログイン名を追加してください。")
                        if let login = store.connection.deniedLogin {
                            Text("この iPhone のログイン名: \(login)").textSelection(.enabled)
                                .accessibilityIdentifier("connection.deniedLogin")
                        }
                        Text("PC と同じ Tailscale アカウントでログインする方法もあります。")
                    }
                    .navigationTitle("PC 側の許可手順")
                    .toolbar { Button("閉じる") { permissionHelp = false } }
                }
            }
        }
    }
}
