import SwiftUI
import UIKit

@MainActor enum SkillSymbol {
    private static let images = NSCache<NSString, UIImage>()
    static func name(skill: ShelfSkill, category: SkillCategory) -> String {
        if let name = skill.symbol, image(name) != nil { return name }
        return category.validSymbol
    }
    static func image(_ name: String) -> UIImage? {
        if let image = images.object(forKey: name as NSString) { return image }
        guard let image = UIImage(systemName: name) else { return nil }
        images.setObject(image, forKey: name as NSString); return image
    }
}
extension ShelfSkill: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SkillSymbolClaudeMark: Shape {
    func path(in rect:CGRect)->Path {
        var path = Path()
        let center = CGPoint(x:rect.midX,y:rect.midY)
        let radius = min(rect.width,rect.height) * 0.4
        for index in 0..<4 {
            let angle = Double(index) * .pi / 4
            let dx = radius * cos(angle), dy = radius * sin(angle)
            path.move(to:.init(x:center.x - dx,y:center.y - dy))
            path.addLine(to:.init(x:center.x + dx,y:center.y + dy))
        }
        return path
    }
}

struct SkillSymbolHexagonMark: Shape {
    func path(in rect:CGRect)->Path {
        var path = Path()
        let radius = min(rect.width,rect.height) * 0.4
        for index in 0..<6 {
            let angle = Double(index) * .pi / 3
            let point = CGPoint(x:rect.midX + radius * cos(angle),y:rect.midY + radius * sin(angle))
            if index == 0 { path.move(to:point) } else { path.addLine(to:point) }
        }
        path.closeSubpath(); return path
    }
}
