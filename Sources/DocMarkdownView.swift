import SwiftUI
import UIKit

struct DocMarkdownContent: View {
    let document: DocMarkdownDocument
    @Bindable var state: DocReaderState
    var textSize: Int
    @ScaledMetric(relativeTo:.body) private var baseSize: CGFloat = 17
    private var size: CGFloat { baseSize * DocReaderState.factors[min(4,max(0,textSize))] }
    private var firstParagraph: Int? { document.blocks.first(where: { $0.kind == .paragraph })?.id }
    var body: some View {
        ForEach(document.blocks) { block in
            DocMarkdownBlockView(block:block, size:size, query:state.showFind ? state.query : "")
                .id(block.id).accessibilityIdentifier("doc.block.\(block.id)")
                .background { if block.id == firstParagraph { DocViewerPaintProbe(kind:"body") } }
        }
    }
}
struct DocMarkdownBlockView: View {
    let block: DocMarkdownBlock
    let size: CGFloat
    var query = ""
    var body: some View {
        Group {
            switch block.kind {
            case .heading(let level):
                VStack(alignment:.leading,spacing:18) {
                    if level == 2 { Divider().padding(.top,18) }
                    Text(styled()).font(.system(size:level == 1 ? size * 23/17 : level == 2 ? size * 1.25 : level == 3 ? size * 1.1 : size,weight:.bold))
                        .padding(.top,level == 1 ? 4 : 10)
                }
            case .paragraph: Text(styled()).lineSpacing(size * 0.65)
            case .bullet(let depth): list(depth:depth,mark:Text("•").foregroundStyle(Color("Accent")))
            case .numbered(let depth,let number):
                list(depth:depth,mark:Text("\(number)").font(.system(size:size * 0.8,weight:.semibold)).foregroundStyle(Color("Accent")).frame(minWidth:25,minHeight:25).background(Color("Accent").opacity(0.15),in:Circle()))
            case .check(let depth,let checked):
                list(depth:depth,mark:Image(systemName:checked ? "checkmark.square" : "square").foregroundStyle(Color("Accent")))
            case .quote:
                HStack(alignment:.top,spacing:12) {
                    Rectangle().fill(Color("Accent").opacity(0.5)).frame(width:3)
                    Text(styled()).foregroundStyle(.secondary).lineSpacing(size * 0.55).frame(maxWidth:.infinity,alignment:.leading)
                }.fixedSize(horizontal:false,vertical:true).padding(12).background(.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
            case .code(let language): DocCodeSnippet(code:block.text, language:language,size:size)
            case .table(let rows):
                if (rows.map(\.count).max() ?? 0) >= 4 { ScrollView(.horizontal) { table(rows).fixedSize(horizontal:true,vertical:false) } }
                else { table(rows) }
            case .rule: Divider().padding(.vertical,12)
            }
        }.font(.system(size:size)).frame(maxWidth:.infinity,alignment:.leading)
            .contextMenu { Button("写す") { UIPasteboard.general.string = String(block.inline.characters) } }
    }
    private func list<Mark:View>(depth:Int, mark:Mark)->some View {
        HStack(alignment:.top,spacing:10) {
            mark.frame(width:25)
            Text(styled()).lineSpacing(size * 0.55).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.leading,CGFloat(min(depth,8)) * 18)
    }
    private func table(_ rows:[[String]])->some View {
        Grid(alignment:.leading,horizontalSpacing:0,verticalSpacing:0) {
            ForEach(Array(rows.enumerated()),id:\.offset) { index,row in
                GridRow {
                    ForEach(Array(row.enumerated()),id:\.offset) { column,cell in
                        Text(index < block.tableInline.count && column < block.tableInline[index].count ? block.tableInline[index][column] : AttributedString(cell)).font(.system(size:size * 0.85,weight:index == 0 ? .semibold : .regular))
                            .frame(minWidth:70,maxWidth:240,alignment:.leading).padding(10)
                            .background(index == 0 ? Color("Accent").opacity(0.1) : Color.secondary.opacity(index % 2 == 0 ? 0.05 : 0.02))
                            .overlay(Rectangle().stroke(.secondary.opacity(0.15),lineWidth:0.5))
                    }
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius:10))
    }
    private func styled()->AttributedString {
        var value = block.inline
        for run in block.inline.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].font = .system(size:size * 0.9,design:.monospaced)
            value[run.range].backgroundColor = .secondary.opacity(0.1)
            let code = String(value[run.range].characters)
            if code.contains("/") || code.contains("\\") {
                value[run.range].foregroundColor = Color("Accent")
            }
        }
        if !query.isEmpty {
            let plain = String(value.characters); var remaining = plain[...]
            while let range = remaining.range(of:query,options:.caseInsensitive) {
                if let start = AttributedString.Index(range.lowerBound,within:value), let end = AttributedString.Index(range.upperBound,within:value) { value[start..<end].backgroundColor = .yellow.opacity(0.45) }
                remaining = remaining[range.upperBound...]
            }
        }
        return value
    }
}
struct DocCodeSnippet: View {
    let code: String; let language: String; let size: CGFloat
    @State private var copied = false
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text(language.isEmpty ? "コード" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { UIPasteboard.general.string = code; copied = true } label: { Label(copied ? "写しました" : "写す",systemImage:"doc.on.doc") }.font(.caption)
            }.padding(10)
            Divider()
            ScrollView(.horizontal) {
                Text(code).font(.system(size:size * 0.85,design:.monospaced)).lineSpacing(5).fixedSize(horizontal:true,vertical:false).padding(12)
            }
        }.background(.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
    }
}
struct DocFrontMatterPanel: View {
    let document: FrontMatterDocument
    var body: some View {
        if document.failure != nil {
            VStack(alignment:.leading,spacing:8) {
                Text("先頭の設定を読めませんでした").foregroundStyle(.orange)
                Text(document.raw ?? "").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            }.padding(14).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
        } else if document.raw != nil {
            DisclosureGroup("先頭の設定") {
                DocSettingsFields(fields:document.fields)
            }.padding(14).background(.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:14))
        }
    }
}
struct DocSettingsFields: View {
    let fields: [FrontMatterField]
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(fields) { field in
                VStack(alignment:.leading,spacing:5) {
                    Text(field.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if field.key == "allowed-tools" { DocFlowTags(values:field.value.strings) }
                    else { Text(field.value.text).font(.callout).textSelection(.enabled) }
                }
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,8)
    }
}
struct DocFlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 7
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout())->CGSize {
        let width = proposal.width ?? 350
        var x:CGFloat = 0; var y:CGFloat = 0; var line:CGFloat = 0
        for child in subviews {
            let size = child.sizeThatFits(.init(width:width,height:nil))
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line,size.height)
        }
        return .init(width:width,height:y + line)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout()) {
        var x = bounds.minX; var y = bounds.minY; var line:CGFloat = 0
        for child in subviews {
            let size = child.sizeThatFits(.init(width:bounds.width,height:nil))
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            child.place(at:.init(x:x,y:y),proposal:.init(width:min(bounds.width,size.width),height:size.height))
            x += size.width + spacing; line = max(line,size.height)
        }
    }
}
struct DocFlowTags: View {
    let values: [String]
    var body: some View {
        DocFlowLayout {
            ForEach(Array(values.enumerated()),id:\.offset) { _,text in
                Text(text).font(.caption).padding(.horizontal,10).padding(.vertical,6).background(Color("Accent").opacity(0.14),in:Capsule())
            }
        }
    }
}
