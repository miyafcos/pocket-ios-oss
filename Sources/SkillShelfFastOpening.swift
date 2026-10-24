import SwiftUI
import UIKit

/// Paint the real first-load placeholders before building the destination's
/// scroll reader/navigation tree. Cached shelves keep their immediate row path.
@MainActor enum SkillShelfFastOpening {
    private static var cover: UIView?
    static func begin(base:String,then navigate:@escaping ()->Void) -> Bool {
        let directory = SkillShelfStubFixture.cacheDirectory
        // Fixture seeding and decoding remain in the screen's constructor.
        // The seeded-cache path must not perform that work twice at the tap.
        if SkillShelfStubFixture.active,
           TalkLaunch.argument("-PocketStubSkillsSeed") == "YES",
           TalkLaunch.argument("-PocketStubSkillsNoCache") != "YES" { return false }
        let file = SkillShelfCache(base:base,directory:directory).file
        guard file.map({ FileManager.default.fileExists(atPath:$0.path) }) != true,
              cover == nil,
              let scene = UIApplication.shared.connectedScenes.first(where:{ $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow) else { return false }
        let view = UIView(frame:window.bounds)
        view.backgroundColor = .systemGroupedBackground
        view.isUserInteractionEnabled = true
        let top = max(window.safeAreaInsets.top,scene.statusBarManager?.statusBarFrame.height ?? 0)
        let title = UILabel()
        title.text = "スキル"
        title.font = UIFontMetrics(forTextStyle:.largeTitle).scaledFont(for:UIFont.systemFont(ofSize:34,weight:.bold))
        title.frame = CGRect(x:14,y:top + 8,width:window.bounds.width - 28,height:title.font.lineHeight + 6)
        view.addSubview(title)
        let controls = SkillShelfLoadingControls.Shapes()
        controls.frame = CGRect(x:12,y:max(top + 70,title.frame.maxY + 10),width:window.bounds.width - 24,height:78)
        view.addSubview(controls)
        let panel = UIView(frame:CGRect(x:12,y:controls.frame.maxY + 12,width:window.bounds.width - 24,height:246))
        panel.backgroundColor = .secondarySystemGroupedBackground
        panel.layer.cornerRadius = 18
        panel.isAccessibilityElement = true
        panel.accessibilityLabel = "スキルの棚を読み込んでいます"
        panel.accessibilityIdentifier = "skills.skeleton"
        let shapes = SkillShelfSkeleton.Shapes()
        shapes.frame = panel.bounds.insetBy(dx:14,dy:14); panel.addSubview(shapes)
        let probe = SkillShelfPaintProbe.Probe(kind:.skeleton,cached:false,onPaint:navigate)
        probe.frame = panel.bounds; panel.addSubview(probe)
        view.addSubview(panel)
        cover = view
        window.addSubview(view)
        return true
    }
    static func destinationPainted() { cover?.removeFromSuperview(); cover = nil }
}
