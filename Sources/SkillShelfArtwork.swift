import SwiftUI
import UIKit

/// Rasterize SF Symbol artwork requested by visible rows and retain it
/// within the icon bounds for later cached shelf opens.
@MainActor enum SkillShelfArtwork {
    private static let cache: NSCache<NSString, UIImage> = {
        let result = NSCache<NSString, UIImage>()
        result.countLimit = 96
        result.totalCostLimit = 12 * 1024 * 1024
        return result
    }()
    private struct Request {
        let id: NSString
        let skill: ShelfSkill
        let category: SkillCategory
        let size: CGFloat
        let scale: CGFloat
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
    }
    private static var pending: [Request] = []
    private static var queued = Set<String>()
    private static var worker: Task<Void, Never>?
    private static var fallback: Task<Void, Never>?
    private static var interacting = false
    static func setInteracting(_ value: Bool) { interacting = value }
    static func appeared() {
        guard fallback == nil, worker == nil, !pending.isEmpty else { return }
        // A detail icon or a shelf with no frequent items has no first-tile
        // probe. It still receives its cache during a later idle interval.
        fallback = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            fallback = nil; startPending()
        }
    }
    static func firstPaintFinished() {
        fallback?.cancel(); fallback = nil
        startPending()
    }
    private static func startPending() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task {
            // First show the original artwork, complete the two visible
            // frames and allow the navigation animation to settle.
            try? await Task.sleep(for: .milliseconds(500))
            while !pending.isEmpty {
                if interacting {
                    try? await Task.sleep(for: .milliseconds(16)); continue
                }
                let request = pending.removeFirst()
                if cache.object(forKey: request.id) == nil,
                   let image = render(skill: request.skill, category: request.category, size: request.size,
                                      scale: request.scale, scheme: request.scheme, contrast: request.contrast) {
                    let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                    cache.setObject(image, forKey: request.id, cost: cost)
                }
                queued.remove(request.id as String)
                // Return to the run loop between individual icons.
                try? await Task.sleep(for: .milliseconds(8))
            }
            worker = nil
        }
    }
    nonisolated static func key(skill: ShelfSkill, category: SkillCategory, size: CGFloat,
                    scale: CGFloat, scheme: ColorScheme, contrast: ColorSchemeContrast) -> String {

        let parts = [skill.symbol ?? category.symbol, category.symbol, category.color, String(skill.isOwn), String(Double(size)),
                     String(Double(scale)), scheme == .dark ? "dark" : "light",
                     contrast == .increased ? "increased" : "standard"]
        return parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    static func image(skill: ShelfSkill, category: SkillCategory, size: CGFloat,
                      scale: CGFloat, scheme: ColorScheme, contrast: ColorSchemeContrast) -> UIImage? {
        guard contrast == .standard else { return nil }
        let id = key(skill: skill, category: category, size: size, scale: scale, scheme: scheme, contrast: contrast) as NSString
        if let image = cache.object(forKey: id) { return image }
        if queued.insert(id as String).inserted {
            pending.append(Request(id: id, skill: skill, category: category, size: size, scale: scale,
                                   scheme: scheme, contrast: contrast))
        }
        return nil
    }
    static func render(skill: ShelfSkill, category: SkillCategory, size: CGFloat,
                       scale: CGFloat, scheme: ColorScheme, contrast: ColorSchemeContrast) -> UIImage? {
        let token = SkillShelfProfile.begin("ArtworkRasterize")
        defer { SkillShelfProfile.end(token) }
        let content = SkillShelfIconArtwork(skill: skill, category: category, size: size)

            .environment(\.colorScheme, scheme)
            .environment(\.displayScale, scale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.uiImage
    }
}
