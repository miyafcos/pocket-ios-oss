import Foundation
import SwiftUI
import UIKit
import UserNotifications

@main
struct PocketApp: App {
    @State private var store = PocketStore()
    init() {
        _ = PocketNetwork.shared
        PocketStub.install()
        PocketDiagnostics.install()
    }
    var body: some Scene {
        WindowGroup { PocketRoot(store: store).environment(store) }
    }
}

/// Where the home screen's leading tools sit under the status-bar clock.
enum TopBarTools {
    // From the phone (iPhone Air, 420 pt wide) on 2026-10-08: at 17:17 the clock's
    // first digit starts 31 pt from the edge, and the bar's leading group started at
    // 20 pt, 11 pt further out. The clock is centred on a fixed point, so its edge
    // moves with the digits (26 to 33 pt across thirty-five screenshots from that
    // phone); 31 pt is the screen that was reported.
    static let clockEdge: CGFloat = 31
    static let measuredWidth: CGFloat = 420
    // The bar's own group at that width: 11 pt either side of a symbol and 8 pt
    // between tools give its 218 pt and the same symbol centres to the pixel.
    static let pad: CGFloat = 11
    static let gap: CGFloat = 8
    static let height: CGFloat = 44

    /// How far in from where the bar put the group its glass starts, or nil to leave
    /// the bar's own group: other widths were not measured. The bar puts an item the
    /// app draws at 24 pt on iOS 26.3 and at 20 pt on iOS 27, so the place is read
    /// (`origin`, in window points) rather than assumed; 20 pt until it is.
    static func inset(screenWidth: CGFloat, origin: CGFloat?) -> CGFloat? {
        guard abs(screenWidth - measuredWidth) < 1 else { return nil }
        return max(0, clockEdge - (origin ?? 20))
    }

    /// One tool's symbol with the room the bar gives it, all of it answering a touch.
    /// Below the standard text size the bar keeps that room and draws its own symbols
    /// smaller, but a view placed in the bar is never told a size below the standard
    /// one: `drawn` carries the phone's size in (the reported phone is set two steps
    /// below), and the symbol is drawn at it over the room the standard one takes.
    static func slot(_ label: some View, drawn: DynamicTypeSize? = nil) -> some View {
        label.labelStyle(.iconOnly)
            .opacity(drawn == nil ? 1 : 0)
            .overlay {
                if let drawn { label.labelStyle(.iconOnly).dynamicTypeSize(drawn).accessibilityHidden(true) }
            }
            .foregroundStyle(Color("Accent"))
            .padding(.horizontal, pad)
            .frame(minWidth: height, minHeight: height)
            .contentShape(Rectangle())
    }
}

struct PocketRoot: View {
    @Bindable var store: PocketStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var drawerOpen = false
    // The pull from the edge and the push on the scrim, as gesture state: SwiftUI
    // clears both itself when the gesture ends or the system cancels it, so an
    // interrupted drag can never leave the drawer parked part of the way out,
    // nor the app switched off behind it.
    @GestureState private var pull = EdgePull()
    @GestureState private var scrimDrag: CGFloat = 0
    // The pull's decision again, for onEnded, which runs after the state above
    // has already been cleared.
    @State private var pullAccepted = false
    // Where the drawer was when the finger lifted, kept for one frame so the
    // settle starts from there rather than jumping when the drag state resets.
    @State private var drawerRelease: CGFloat?
    @State private var pendingLink: DeepLink?
    // The launcher is a sheet rather than a pushed screen: it is a decision that
    // ends in a seat, not a place in the app, and the situation list stays
    // behind it the way the desktop launcher sits inside its workspace.
    @State private var launcher: LaunchStore?
    @State private var pendingLaunchedTabID: String?
    @State private var revealedTabID: String?
    // Set when the app goes to the background, so coming back can be measured.
    @State private var wentBackground = false
    @State private var homeTab = HomeTab.activity
    // Where the bar put the home screen's tools, read once with the drawer away (TopBarTools).
    @State private var toolOrigin: CGFloat?
    @State private var conversationQuery = ""
    @State private var conversationFolder = ConversationFolder.all

    // Whether the pull now in progress began on the screen's edge and ran
    // sideways, decided once on its first movement, and how far it has come.
    private struct EdgePull: Equatable {
        var accepted: Bool?
        var shown: CGFloat = 0
    }

    private var pollKey: String { "\(scenePhase == .active):\(store.base)" }

    var body: some View {
        // The drawer slides in from the left over the app, the way the web app
        // does it, and nudges the app aside a little for depth. A sheet from the
        // bottom could only be opened from the toolbar, and read as a different
        // control altogether.
        GeometryReader { geometry in
            let width = store.motion.values.drawerHeight.width(for: geometry.size.width)
            let progress = drawerProgress(width: width)
            ZStack(alignment: .leading) {
                screens(toolInset: TopBarTools.inset(screenWidth: geometry.size.width, origin: toolOrigin),
                        compactTools: geometry.size.width < 390)
                    .offset(x: width * Motion.drawerPush * progress)
                    // Also while a pull is under way: the row the finger came down
                    // on must not fire when it lifts, or the drawer would open over
                    // a screen the person never chose.
                    .disabled(drawerOpen || pull.accepted == true)
                    .accessibilityHidden(drawerOpen)
                    // The pull from the left edge opens the drawer on the 状況 screen
                    // only. Deeper in, that edge belongs to the stack's swipe back,
                    // and a strip laid over the screen would have taken it away.
                    .simultaneousGesture(edgeDrag(width: width), including: store.navigationPath.isEmpty ? .all : .subviews)
                // The scrim stays in place and fades with the drawer, so it never
                // pops in or out; it only answers touches while the drawer is open.
                Color.black.opacity(Motion.drawerScrim * progress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { setDrawer(false) }
                    .gesture(scrimPush(width: width))
                    .allowsHitTesting(drawerOpen)
                    .accessibilityHidden(!drawerOpen)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("引き出しを閉じる")
                    .accessibilityIdentifier("drawer.scrim")
                DrawerView(store: store, close: { setDrawer(false) }) { destination in show(destination) }
                    .frame(width: width)
                    .offset(x: width * (progress - 1))
                    .tint(Color("Accent")) // The drawer is its own stack and does not inherit the root tint.
                    .accessibilityHidden(!drawerOpen)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.keyboard)
        // Nothing else can be reached until this phone knows a PC: the sheet is
        // the first screen on a fresh install, and cannot be swiped away then.
        // A measuring run is handed the stub's own machine (EvidenceMachineFixture)
        // so the sheet stays out of the screens it is timing.
        .fullScreenCover(isPresented: Binding(
            get: { store.machines.machines.isEmpty || store.pairingOpen },
            set: { store.pairingOpen = $0 })) {
                PairingView(store: store).interactiveDismissDisabled(store.machines.machines.isEmpty)
        }
        // Changing which PC is read puts the app back on the 状況 screen, so the
        // drawer must not stay out over it.
        .onChange(of: store.base) { _, _ in if drawerOpen { setDrawer(false) } }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
        }
        .onChange(of: store.navigationPath) { old, new in
            if let id = Destination.newlyOpenedTalk(old: old, new: new) {
                store.recent.recordOpen(sessionID: id)
            }
            // Going somewhere new, whether pushed or put in place from the drawer;
            // never on the way back.
            if let top = new.last, new.count >= old.count, top != old.last { store.motion.openRow() }
        }
        .onChange(of: reduceMotion, initial: true) { _, value in store.motion.reduceMotion = value }
        .task(id: pollKey) {
            if scenePhase == .active { await store.pollOverview() }
        }
        // Which machine is reachable, asked on coming to the front and every ten
        // seconds while in front; the bands and the talk composer read the answer.
        .task(id: pollKey) {
            guard scenePhase == .active else { return }
            ConnectionMonitor.shared.onWinBack = { Task { await HubStore.shared.flushPendingPrefs() } }
            await ConnectionMonitor.shared.runWhileActive(winBase: store.base) { HarnessEndpoint.base() }
        }
        .task {
            UNUserNotificationCenter.current().delegate = PocketAlertDelegate.shared
            PocketAlertDelegate.shared.onOpen = { talk in
                guard Destination.validID(talk) else { return }
                pendingLink = .talk(talk)
            }
            // Asking on first launch would be a prompt nobody asked for; the
            // setting is where it is turned on, and that is where iOS is asked.
            if PocketAlerts.shared.enabled { await PocketAlerts.shared.ask() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let watch = MainStallWatch.selected(stubActive: PocketStub.active, activityActive: PocketStub.activityActive)
            if phase == .active { watch.start() }
            else { watch.stop() }
            if phase == .active {
                PocketStub.foreground()
                ConnectionMonitor.shared.beginForeground()
                if PocketMetrics.launched() { wentBackground = false }
                PocketAlerts.shared.clearDelivered()
            }
            if phase == .background { wentBackground = true }
            if phase == .active, wentBackground {
                wentBackground = false
                let screen: String
                switch store.navigationPath.last {
                case nil: screen = "situation" // Both root tabs refresh through the existing list metric.
                case .search?: screen = "situation"
                case .talk?: screen = "talk"
                default: screen = "other"
                }
                PocketMetrics.cameToForeground(screen: screen)
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if HubLaunch.query(arguments: args) != nil { apply(.hub) }
            if TalkLaunch.dryRun,
               let index = args.firstIndex(of: "-PocketEvidenceTalk"), args.indices.contains(index + 1),
               Destination.validID(args[index + 1]) {
                apply(.talk(args[index + 1]))
            }
            if TalkLaunch.evidenceFlag("-PocketEvidenceHarness") { store.navigationPath = [.hermes] }
        }
        // 成果物 waits on the index and on the reader's compiled guard, and both
        // can be ready before the screen is asked for. Behind the situation
        // screen's own work, so the first thing shown is not held up for them.
        .task(priority: .utility) {
            async let guardRules: Void = HubDocSecurity.warmContentRuleList()
            await HubStore.shared.refresh()
            await guardRules
        }
        // Warming the rooms behind the list runs from PocketStore.refreshOverview,
        // on every fresh list (TalkWarmer), not from here.
        .onOpenURL { url in handle(url) }
        // A universal link usually arrives through onOpenURL, but a cold start can deliver the
        // browsing activity instead; both funnel into the same handler.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { handle(url) }
        }
    }

    private func screens(toolInset: CGFloat?, compactTools: Bool) -> some View {
        NavigationStack(path: $store.navigationPath) {
            PocketHome(store: store, selected: $homeTab,
                       covered: launcher != nil || drawerOpen || store.pairingOpen || store.machines.machines.isEmpty) {
                store.navigationPath.append($0)
            }
                .navigationTitle(homeTab.title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        if compactTools {
                            // UIKit also exposes the principal hosting view as
                            // a title; exclude that native placeholder as well.
                            CompactTitlePlaceholder().frame(width: 1, height: 1)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        } else {
                            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                        }
                    }
                }
                .toolbar {
                    if let toolInset {
                        // The four tools as one group the app draws itself. The bar
                        // starts its own group at 20 pt and takes no offset: a spacer
                        // placed first is dropped, and an empty item pushes the group
                        // 56 pt and the trailing tools into a menu (iOS 26.3).
                        ToolbarItem(placement: .topBarLeading) {
                            // Plain: the bar's own style adds room of its own around a
                            // tool in an app-drawn group, so the slot is all the room.
                            // The fourth was a view of the app's in the bar before this,
                            // and so already kept the standard size on a smaller setting.
                            let drawn: DynamicTypeSize? = textSize < .large ? textSize : nil
                            HStack(spacing: TopBarTools.gap) {
                                Button { setDrawer(true) } label: { TopBarTools.slot(Label("引き出し", systemImage: "rectangle.split.3x1"), drawn: drawn) }
                                    .accessibilityIdentifier("open.drawer")
                                    .buttonStyle(.plain)
                                NavigationLink(value: Destination.hub) { TopBarTools.slot(Label("成果物", systemImage: "doc.text"), drawn: drawn) }
                                    .accessibilityIdentifier("open.hub")
                                    .buttonStyle(.plain)
                                NavigationLink(value: Destination.files) { TopBarTools.slot(Label("ファイル", systemImage: "folder"), drawn: drawn) }
                                    .accessibilityIdentifier("open.files")
                                    .buttonStyle(.plain)
                                NavigationLink(value: Destination.agentDesign) { TopBarTools.slot(Label("エージェント設計", image: "skill.swordshield")) }
                                    .accessibilityIdentifier("open.agentdesign")
                                    .buttonStyle(AgentDesignNavigationStyle())
                            }
                            // These are fixed toolbar icons: larger body text must
                            // not widen the measured group into the overflow menu.
                            .dynamicTypeSize(.large)
                            .fixedSize()
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .padding(.leading, toolInset)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { x in
                                // Read once, on this screen with the drawer away, and not while
                                // the bar first lays the item out off to the left. Following the
                                // item after that fed its own padding back into the bar: it
                                // moves a fraction of a point as its width changes, and slides
                                // while a screen is pushed, and on iOS 27 the app spun at
                                // launch and on every push.
                                guard toolOrigin == nil, store.navigationPath.isEmpty, !drawerOpen,
                                      pull.accepted != true, drawerRelease == nil,
                                      x >= 0, x < TopBarTools.clockEdge else { return }
                                toolOrigin = x
                            }
                        }.sharedBackgroundVisibility(.hidden)
                    } else if compactTools {
                        ToolbarItem(placement: .topBarLeading) {
                            HStack(spacing: 0) {
                                Button { setDrawer(true) } label: { Label("引き出し", systemImage: "rectangle.split.3x1") }
                                    .accessibilityIdentifier("open.drawer")
                                NavigationLink(value: Destination.hub) { Label("成果物", systemImage: "doc.text") }
                                    .accessibilityIdentifier("open.hub")
                                NavigationLink(value: Destination.files) { Label("ファイル", systemImage: "folder") }
                                    .accessibilityIdentifier("open.files")
                                NavigationLink(value: Destination.agentDesign) {
                                    Label("エージェント設計", image: "skill.swordshield").labelStyle(.iconOnly)
                                        .font(.system(size: 17)).frame(width: TopBarTools.height, height: TopBarTools.height)
                                        .contentShape(Rectangle())
                                }
                                    .accessibilityIdentifier("open.agentdesign")
                                    .buttonStyle(AgentDesignNavigationStyle())
                            }
                            .buttonStyle(CompactLeadingToolStyle())
                            .dynamicTypeSize(.large)
                            .fixedSize()
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("引き出し", systemImage: "rectangle.split.3x1") { setDrawer(true) }
                                .accessibilityIdentifier("open.drawer")
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink(value: Destination.hub) { Label("成果物", systemImage: "doc.text") }
                                .accessibilityIdentifier("open.hub")
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink(value: Destination.files) { Label("ファイル", systemImage: "folder") }
                                .accessibilityIdentifier("open.files")
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink(value: Destination.agentDesign) {
                                ZStack { Label("エージェント設計", image: "skill.swordshield").labelStyle(.iconOnly) }
                            }.accessibilityIdentifier("open.agentdesign")
                                .buttonStyle(AgentDesignNavigationStyle())
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Three compact slots leave the measured Air leading group intact.
                        HStack(spacing: 0) {
                            NavigationLink(value: Destination.search) { Label("席と会話を探す", systemImage: "magnifyingglass") }
                                .accessibilityIdentifier("open.search")
                            Button { launcher = LaunchStore(base: store.base, recent: store.recent) } label: {
                                Label("新しいタブ", systemImage: "plus")
                            }.accessibilityIdentifier("open.launcher")
                            NavigationLink(value: Destination.settings) { Label("設定", systemImage: "gearshape") }
                                .accessibilityIdentifier("open.settings")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(HomeTrailingToolStyle())
                        .fixedSize()
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }.sharedBackgroundVisibility(.hidden)
                }
                .sheet(item: Binding(get: { launcher }, set: { value in
                    // The binding also receives interactive swipe dismissal.
                    if value == nil { dismissLauncher() }
                    else { launcher = value }
                }), onDismiss: {
                    guard let tabID = pendingLaunchedTabID else { return }
                    pendingLaunchedTabID = nil
                    showLaunchedSeat(tabID)
                }) { launchStore in
                    LaunchView(
                        store: launchStore,
                        workspaces: store.overview?.rows ?? [],
                        openTalk: { sessionID in
                            launcher = nil
                            show(.talk(sessionID))
                        },
                        showInList: { tabID in revealLaunchedTab(tabID) },
                        close: { dismissLauncher() }
                    )
                    .task {
                        await launchStore.load(
                            workspaces: store.overview?.rows ?? [],
                            activeWorkspaceID: store.overview?.activeWorkspaceId
                        )
                    }
                }
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .search:
                        ConversationsView(store: store, revealedTabID: $revealedTabID,
                                          navigate: { store.navigationPath.append($0) },
                                          query: $conversationQuery, folder: $conversationFolder)
                    case .background: BackgroundSeatsView(store: store) { store.navigationPath.append($0) }
                    case .settings: SettingsView(store: store)
                    case .talk(let id): TalkScreen(sessionID: id, base: store.base, motion: store.motion, pocket: store).id(id + store.base)
                    case .files:
                        FileExplorerScreen(machines: store.machines) { base, step in
                            store.navigationPath.append(.fileFolder(base: base, step: step))
                        }
                    case .fileFolder(let base, let step):
                        FolderScreen(base: base, step: step, navigate: { next in
                            store.navigationPath.append(.fileFolder(base: base, step: next))
                        }).id(base + step.path)
                    case .skills: SkillShelfScreen(base: store.base).id(store.base)
                    case .agentDesign: AgentDesignScreen(base: store.base).id(store.base)
                    case .hub: HubListView()
                    case .hubDoc(let id): HubDocView(id: id)
                    // The harness is reached on the Mac mini (HarnessEndpoint), so it
                    // keeps working while Windows is off.
                    case .hermes:
                        HermesHomeScreen(base: HarnessEndpoint.base()) { store.navigationPath.append(.hermesRoom($0)) }
                            .harnessConnectionBand()
                    case .hermesRoom(let room):
                        HermesTalkScreen(room: room, base: HarnessEndpoint.base())
                            .harnessConnectionBand()
                    default:
                        if let client = try? APIClient(base: store.base), let url = client.webURL(destination) {
                            WebScreen(url: url, title: destination.title)
                                .id(url)
                        }
                    }
                }
        }
        .preferredColorScheme(TalkLaunch.evidenceAppearance)
        .tint(Color("Accent")) // One accent for links, buttons and the drawer close control.
    }

    private func dismissLauncher() {
        if let route = launcher?.dismiss(), case .list(let tabID) = route {
            pendingLaunchedTabID = tabID
            store.navigationPath = []
        }
        launcher = nil
    }

    private func revealLaunchedTab(_ tabID: String) {
        store.navigationPath = []
        if launcher != nil {
            pendingLaunchedTabID = tabID
            launcher = nil
        } else {
            // The launch POST can finish after dismissal. There is no future
            // onDismiss in that case, so reveal its row immediately.
            showLaunchedSeat(tabID)
        }
    }

    private func showLaunchedSeat(_ tabID: String) {
        conversationQuery = ""; conversationFolder = .all
        revealedTabID = tabID
        store.navigationPath = [.search]
        Task { await store.refreshOverview() }
    }

    // 0 when the drawer is away, 1 when it is fully out; in between only while a
    // finger is moving it or for the one frame after it lifts.
    private func drawerProgress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return drawerOpen ? 1 : 0 }
        let resting: CGFloat = drawerOpen ? width : 0
        let shown = drawerRelease ?? max(0, min(width, resting + pull.shown + scrimDrag))
        return shown / width
    }

    // The pull that opens the drawer runs alongside the 状況 list's own scrolling.
    // It only counts when it starts on the edge and its first movement is
    // sideways; a scroll that begins near the edge is left to the list.
    private func edgeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($pull) { value, pull, _ in
                if pull.accepted == nil {
                    pull.accepted = value.startLocation.x <= Motion.drawerEdge
                        && abs(value.translation.width) > abs(value.translation.height)
                    pullAccepted = pull.accepted == true
                }
                guard pull.accepted == true else { return }
                pull.shown = max(0, min(width, value.translation.width))
            }
            .onEnded { value in
                let accepted = pullAccepted
                pullAccepted = false
                if accepted { settleDrawer(width: width, resting: 0, after: value) }
            }
    }

    private func scrimPush(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($scrimDrag) { value, drag, _ in drag = max(-width, min(0, value.translation.width)) }
            .onEnded { value in settleDrawer(width: width, resting: width, after: value) }
    }

    private func settleDrawer(width: CGFloat, resting: CGFloat, after value: DragGesture.Value) {
        let shown = max(0, min(width, resting + value.translation.width))
        // A flick decides by itself; a slow drag settles to whichever side is nearer.
        let predicted = value.predictedEndTranslation.width
        let open = abs(predicted) > width / 2 ? predicted > 0 : shown > width / 2
        // Hold the drawer where the finger left it: the drag state goes back to
        // zero as soon as this returns, and the settle has to start from here.
        drawerRelease = shown
        Task { @MainActor in
            withAnimation(store.motion.drawerAnimation) {
                drawerRelease = nil
                drawerOpen = open
            }
            if !open { applyPendingLink() }
        }
    }

    private func setDrawer(_ open: Bool) {
        drawerRelease = nil
        if drawerOpen != open {
            withAnimation(store.motion.drawerAnimation) { drawerOpen = open }
        }
        if !open { applyPendingLink() }
    }

    // A row on the drawer goes to that place from the 状況 screen rather than
    // stacking on whatever was open, so one step back is always 状況. The
    // screen is put in place first, without a slide of its own, and the drawer
    // then closes over it; two slides at once left the app half-way across.
    private func show(_ destination: Destination) {
        if store.navigationPath != [destination] {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { store.navigationPath = [destination] }
        }
        setDrawer(false)
    }

    private func handle(_ url: URL) {
        if TalkEvidence.accept(url) { return }
        guard let link = DeepLink.any(url, base: store.base, machines: store.machines.machines) else { return }
        if drawerOpen {
            pendingLink = link
            setDrawer(false)
        } else { apply(link) }
    }

    private func applyPendingLink() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        apply(link)
    }

    private func apply(_ link: DeepLink) {
        store.navigationPath = []
        switch link {
        case .pair(let base, let name):
            store.beginPairing(PairingCandidate(base: base, name: name))
        case .home: break
        case .drawer: setDrawer(true)
        case .settings: store.navigationPath = [.settings]
        case .talk(let id): store.navigationPath = [.talk(id)]
        case .webTalk(let id, let base): store.openWebTalk(id, base: base)
        case .hub: store.navigationPath = [.hub]
        // The shelf sits under 成果物, so the way back from a document is the list.
        case .hubDoc(let id): store.navigationPath = [.hub, .hubDoc(id)]
        }
    }
}

private struct CompactTitlePlaceholder: UIViewRepresentable {
    func makeUIView(context: Context) -> Placeholder { Placeholder(frame: .zero) }
    func updateUIView(_ view: Placeholder, context: Context) { view.excludeTitle() }

    final class Placeholder: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); excludeTitle() }
        override func layoutSubviews() { super.layoutSubviews(); excludeTitle() }

        func excludeTitle() {
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            var ancestor: UIView? = superview
            while let view = ancestor {
                if let bar = view as? UINavigationBar {
                    // Touch only the title containing this compact placeholder.
                    // A pushed screen may already have a different top item.
                    if let title = bar.topItem?.titleView, isDescendant(of: title) {
                        title.isHidden = true
                        title.isUserInteractionEnabled = false
                        title.isAccessibilityElement = false
                        title.accessibilityElementsHidden = true
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct CompactLeadingToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.labelStyle(.iconOnly).font(.system(size: 17))
            .foregroundStyle(Color("Accent"))
            .frame(width: TopBarTools.height, height: TopBarTools.height)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct HomeTrailingToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17))
            .foregroundStyle(Color("Accent"))
            .frame(width: 36, height: TopBarTools.height)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
