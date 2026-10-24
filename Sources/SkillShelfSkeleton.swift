import SwiftUI
import UIKit

/// The first viewport needs only eight plain shapes. A single native view
/// avoids both nested layout and first-use Canvas rendering setup.
struct SkillShelfSkeleton: UIViewRepresentable {
    func makeUIView(context: Context) -> Shapes { Shapes() }
    func updateUIView(_ view: Shapes, context: Context) { view.setNeedsDisplay() }
    final class Shapes: UIView {
        init() {
            super.init(frame: .zero)
            isOpaque = false; backgroundColor = .clear; contentMode = .redraw
            isUserInteractionEnabled = false; isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ rect: CGRect) {
            UIColor.quaternaryLabel.setFill()
            func shape(_ rect: CGRect, _ radius: CGFloat) {
                UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
            }
            shape(CGRect(x: 0, y: 0, width: 130, height: 24), 8)
            for row in 0..<3 {
                let y = CGFloat(40 + row * 60)
                shape(CGRect(x: 0, y: y, width: 38, height: 38), 10)
                shape(CGRect(x: 50, y: y + 2, width: bounds.width * 0.55, height: 15), 4)
                shape(CGRect(x: 50, y: y + 24, width: bounds.width * 0.7, height: 11), 4)
            }
        }
    }
}

/// Show plain placeholders before constructing the first search input.
struct SkillShelfLoadingControls:UIViewRepresentable {
    func makeUIView(context:Context)->Shapes { Shapes() }
    func updateUIView(_ view:Shapes,context:Context) {}
    final class Shapes:UIView {
        init() { super.init(frame:.zero); isOpaque = false; backgroundColor = .clear; isAccessibilityElement = false; isUserInteractionEnabled = false }
        required init?(coder:NSCoder) { fatalError() }
        override func draw(_ rect:CGRect) {
            UIColor.quaternaryLabel.setFill()
            UIBezierPath(roundedRect:CGRect(x:0,y:0,width:bounds.width,height:36),cornerRadius:10).fill()
            let width = (bounds.width - 21) / 4
            for index in 0..<4 {
                UIBezierPath(roundedRect:CGRect(x:CGFloat(index) * (width + 7),y:48,width:width,height:30),cornerRadius:15).fill()
            }
        }
    }
}
