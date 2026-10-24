import SwiftUI

#if DEBUG
private struct ActivityRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Actual layout frames for UI evidence; normal launches keep the row's accessibility unchanged.
private struct ActivityRowGeometry: ViewModifier {
    static let enabled = TalkLaunch.evidenceFlag("-PocketEvidenceActivityRows")
    @State private var frames: [String: CGRect] = [:]

    private var value: String {
        ["avatar", "name", "time"].compactMap { part -> String? in
            guard let frame = frames[part] else { return nil }
            return "\(part)=\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"
        }.joined(separator: " ")
    }

    func body(content: Content) -> some View {
        content.onPreferenceChange(ActivityRowFrames.self) { [binding = $frames] value in
            binding.wrappedValue = value
        }.accessibilityValue(value)
    }
}
#endif

extension View {
    @ViewBuilder func activityRowPart(_ part: String) -> some View {
        #if DEBUG
        if ActivityRowGeometry.enabled {
            background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ActivityRowFrames.self,
                                           value: [part: geometry.frame(in: .global)])
                }
            }
        } else { self }
        #else
        self
        #endif
    }

    @ViewBuilder func activityRowGeometry() -> some View {
        #if DEBUG
        if ActivityRowGeometry.enabled { modifier(ActivityRowGeometry()) }
        else { self }
        #else
        self
        #endif
    }
}
