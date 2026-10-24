import SwiftUI

struct CodeViewerContent: View {
    let lines: [CodeViewerLine]
    @Bindable var state: DocReaderState
    var textSize: Int
    @ScaledMetric(relativeTo:.body) private var baseSize: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    private var size: CGFloat { baseSize * DocReaderState.factors[min(4,max(0,textSize))] }
    var body: some View {
        Group {
            if state.wrap { rows }
            else { ScrollView(.horizontal) { rows.fixedSize(horizontal:true,vertical:false) } }
        }.accessibilityIdentifier("viewer.code")
    }
    private var rows: some View {
        LazyVStack(alignment:.leading,spacing:5) {
            ForEach(lines) { line in
                HStack(alignment:.top,spacing:12) {
                    Text("\(line.id)").font(.system(size:size * 0.85,design:.monospaced)).foregroundStyle(.secondary)
                        .frame(width:CGFloat(max(3,String(lines.count).count)) * size * 0.65,alignment:.trailing)
                        .accessibilityIdentifier("viewer.line.\(line.id)")
                    Text(styled(line)).font(.system(size:size,design:.monospaced)).lineSpacing(5)
                        .frame(maxWidth:state.wrap ? .infinity : nil,alignment:.leading).textSelection(.enabled)
                }.id(line.id).accessibilityElement(children:.contain).accessibilityIdentifier("doc.block.\(line.id)")
            }
        }.frame(maxWidth:state.wrap ? .infinity : nil,alignment:.leading)
    }
    private func color(_ kind:CodeViewerToken.Kind)->Color {
        let dark = scheme == .dark
        switch kind {
        case .plain: return .primary
        case .keyword: return dark ? Color(red:1,green:0.45,blue:0.72) : Color(red:0.65,green:0.13,blue:0.62)
        case .string: return dark ? Color(red:1,green:0.43,blue:0.35) : Color(red:0.76,green:0.16,blue:0.13)
        case .comment: return dark ? Color(red:0.52,green:0.61,blue:0.63) : Color(red:0.35,green:0.43,blue:0.38)
        case .number: return dark ? Color(red:0.77,green:0.67,blue:1) : Color(red:0.23,green:0.28,blue:0.76)
        case .type: return dark ? Color(red:0.63,green:0.82,blue:0.85) : Color(red:0.1,green:0.43,blue:0.49)
        }
    }
    private func styled(_ line:CodeViewerLine)->AttributedString {
        var value = AttributedString()
        for token in line.tokens { var part = AttributedString(token.text); part.foregroundColor = color(token.kind); value += part }
        if state.showFind && !state.query.isEmpty {
            let plain = String(value.characters); var rest = plain[...]
            while let range = rest.range(of:state.query,options:.caseInsensitive) {
                if let start = AttributedString.Index(range.lowerBound,within:value), let end = AttributedString.Index(range.upperBound,within:value) { value[start..<end].backgroundColor = .yellow.opacity(0.4) }
                rest = rest[range.upperBound...]
            }
        }
        return value
    }
}
