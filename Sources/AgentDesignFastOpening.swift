import UIKit

/// Paint the real first-load placeholders before constructing the native list.
/// Cached folders continue straight to their saved catalog.
@MainActor enum AgentDesignFastOpening {
    private static var cover: UIView?
    static func begin(base: String, then navigate: @escaping () -> Void) -> Bool {
        // Seeding belongs to the screen initializer, not the toolbar action.
        if AgentDesignStub.active,
           TalkLaunch.argument("-PocketStubAgentDesignNoSeed") != "YES" { return false }
        let folder = UserDefaults.standard.string(forKey:"agentdesign.folder." + AgentDesignCache.key(base)) ?? "home"
        let file = AgentDesignCache(base:base,directory:AgentDesignCache.directory).file(folder)
        guard file.map({ FileManager.default.fileExists(atPath:$0.path) }) != true,
              cover == nil,
              let scene = UIApplication.shared.connectedScenes.first(where:{ $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where:\.isKeyWindow) else { return false }
        let view = UIView(frame:window.bounds)
        view.backgroundColor = .systemGroupedBackground
        view.isUserInteractionEnabled = true
        let top = max(window.safeAreaInsets.top,scene.statusBarManager?.statusBarFrame.height ?? 0)
        let title = UILabel()
        title.text = "エージェント設計"
        title.font = UIFontMetrics(forTextStyle:.largeTitle).scaledFont(for:UIFont.systemFont(ofSize:34,weight:.bold))
        title.frame = CGRect(x:20,y:top + 8,width:window.bounds.width - 40,height:title.font.lineHeight + 6)
        view.addSubview(title)
        let panel = UIView(frame:CGRect(x:20,y:max(top + 80,title.frame.maxY + 18),width:window.bounds.width - 40,height:130))
        panel.backgroundColor = .secondarySystemGroupedBackground
        panel.layer.cornerRadius = 16
        panel.isAccessibilityElement = true
        panel.accessibilityLabel = "目録を読んでいます"
        panel.accessibilityIdentifier = "agentdesign.skeleton"
        let label = UILabel()
        label.text = "目録を読んでいます"
        label.font = UIFont.preferredFont(forTextStyle:.subheadline)
        label.textColor = .secondaryLabel
        label.frame = CGRect(x:16,y:16,width:panel.bounds.width - 32,height:28)
        panel.addSubview(label)
        for (index,width) in [panel.bounds.width - 32,panel.bounds.width * 0.64].enumerated() {
            let line = UIView(frame:CGRect(x:16,y:62 + CGFloat(index) * 26,width:width,height:10))
            line.backgroundColor = .tertiarySystemFill
            line.layer.cornerRadius = 5
            panel.addSubview(line)
        }
        let probe = AgentDesignPaintProbe.Probe(content:false,onPaint:navigate)
        probe.frame = panel.bounds
        panel.addSubview(probe)
        view.addSubview(panel)
        cover = view
        window.addSubview(view)
        return true
    }
    static func destinationPainted() { cover?.removeFromSuperview(); cover = nil }
}
