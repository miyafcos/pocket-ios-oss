import SwiftUI

// Measurement only: how much of the room's time goes into reading its own
// text again. Every body evaluation parses from scratch.
enum TalkMarkdownCost {
    nonisolated(unsafe) static var parses = 0
    nonisolated(unsafe) static var micros = 0
    nonisolated(unsafe) static var chars = 0
}
enum TalkMarkdown {
    enum Block: Equatable {
        case heading(Int, String), paragraph(String), bullet(String, String, Int)
        case code(String, String), quote(String), rule, table(Table)
    }
    // A GFM table, kept as cells so the view can lay it out as a real table.
    // Until now the raw pipes went to the code body, which on a phone is a wall
    // of text no one can read.
    struct Table: Equatable {
        var header: [String]
        var rows: [[String]]
        var alignments: [HorizontalAlignment]
        var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }
        static func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }
            if value.hasSuffix("|") && !value.hasSuffix("\\|") { value.removeLast() }
            var cells: [String] = [], current = "", escaped = false
            for character in value {
                if escaped { current.append(character); escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                else { current.append(character) }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }
        static func alignment(_ marker: String) -> HorizontalAlignment {
            let value = marker.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(":") && value.hasSuffix(":") && value.count > 1 { return .center }
            return value.hasSuffix(":") ? .trailing : .leading
        }
        init(lines: [String]) {
            header = lines.first.map(Self.cells) ?? []
            alignments = lines.count > 1 ? Self.cells(lines[1]).map(Self.alignment) : []
            rows = lines.dropFirst(2).map(Self.cells)
        }
        func alignment(_ column: Int) -> HorizontalAlignment {
            alignments.indices.contains(column) ? alignments[column] : .leading
        }
    }
    static func parse(_ source: String) -> [Block] {
        let began = TalkLaunch.measuring ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if TalkLaunch.measuring {
                TalkMarkdownCost.parses += 1
                TalkMarkdownCost.chars += source.count
                TalkMarkdownCost.micros += Int((DispatchTime.now().uptimeNanoseconds - began) / 1000)
            }
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = []
        var i = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while i < lines.count {
            let line = lines[i], trim = line.trimmingCharacters(in: .whitespaces)
            if trim.isEmpty { flush(); i += 1; continue }
            if trim.hasPrefix("\u{0060}\u{0060}\u{0060}") || trim.hasPrefix("~~~") {
                flush()
                let marker = String(trim.prefix(while: { $0 == trim.first }))
                let language = String(trim.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []; i += 1
                while i < lines.count {
                    let closing = lines[i].trimmingCharacters(in: .whitespaces)
                    if closing.count >= marker.count && closing.allSatisfy({ $0 == marker.first }) { i += 1; break }
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(language, code.joined(separator: "\n"))); continue
            }
            if let match = capture(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, trim) {
                flush(); blocks.append(.heading(match[0].count, match[1])); i += 1; continue
            }
            let rule = trim.filter { !$0.isWhitespace }
            if rule.count >= 3 && ["-", "*", "_"].contains(String(rule.prefix(1))) && Set(rule).count == 1 {
                flush(); blocks.append(.rule); i += 1; continue
            }
            if trim.hasPrefix(">") {
                flush(); var quote: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var value = lines[i].trimmingCharacters(in: .whitespaces); value.removeFirst()
                    if value.hasPrefix(" ") { value.removeFirst() }
                    quote.append(value); i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n"))); continue
            }
            if let match = capture(#"^(\s*)([-+*]|\d+[.)])\s+(.+)$"#, line) {
                flush()
                let marker = ["-", "+", "*"].contains(match[1]) ? "•" : match[1]
                blocks.append(.bullet(marker, match[2], match[0].count)); i += 1; continue
            }
            if trim.contains("|"), i + 1 < lines.count,
               lines[i + 1].range(of: #"^\s*\|?[\s:|-]+\|[\s:|-]*$"#, options: .regularExpression) != nil {
                flush(); var table = [line]; i += 1
                while i < lines.count && lines[i].contains("|") { table.append(lines[i]); i += 1 }
                blocks.append(.table(Table(lines: table))); continue
            }
            paragraph.append(line); i += 1
        }
        flush(); return blocks
    }
    static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map {
            Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
    }
    static func inline(_ text: String) -> AttributedString {
        var value = (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs {
            if let link = run.link, !["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                value[run.range].link = nil
            }
        }
        return TalkLinks.decorate(value)
    }
}
struct TalkMarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(TalkMarkdown.parse(text).enumerated()), id: \.offset) { _, block in blockView(block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func blockView(_ block: TalkMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            TalkInlineText(text: text, style: level <= 2 ? .headline : .subheadline)
                .fontWeight(.semibold).padding(.top, 10).accessibilityAddTraits(.isHeader)
        case .paragraph(let text): TalkInlineText(text: text)
        case .bullet(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(PocketType.text)
                TalkInlineText(text: text).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(min(indent, 12)) * 4 + 8)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                if !language.isEmpty { Text(language).font(.caption).foregroundStyle(.secondary) }
                codeBody(code)
            }.padding(10).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        case .table(let table): TalkTableView(table: table)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(.tertiary).frame(width: 3)
                TalkInlineText(text: text).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .rule: Divider().padding(.vertical, 4)
        }
    }
    private func codeBody(_ code: String) -> some View {
        ScrollView(.horizontal) {
            Text(code).font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
        }
    }
}
// Narrow tables wrap inside the screen; wider ones scroll sideways with a fixed
// column, which beats squeezing six columns of Japanese into 390 points.
struct TalkTableView: View {
    let table: TalkMarkdown.Table
    private var scrolls: Bool { table.columns > 3 }
    var body: some View {
        Group {
            if scrolls { ScrollView(.horizontal) { grid(width: 148) } } else { grid(width: nil) }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
    private func grid(width: CGFloat?) -> some View {
        // The identifier sits on the grid itself: a plain container does not
        // always become an element that can be found from outside.
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 7) {
            GridRow {
                ForEach(0..<table.columns, id: \.self) { column in
                    cell(table.header.indices.contains(column) ? table.header[column] : "", column, head: true, width: width)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal).gridCellColumns(table.columns)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<table.columns, id: \.self) { column in
                        cell(row.indices.contains(column) ? row[column] : "", column, head: false, width: width)
                    }
                }
                if index < table.rows.count - 1 {
                    Divider().gridCellUnsizedAxes(.horizontal).gridCellColumns(table.columns).opacity(0.4)
                }
            }
        }
        .accessibilityIdentifier("talk.table")
    }
    @ViewBuilder private func cell(_ text: String, _ column: Int, head: Bool, width: CGFloat?) -> some View {
        let alignment = table.alignment(column)
        VStack(alignment: alignment, spacing: 0) {
            TalkInlineText(text: text, style: .footnote)
                .fontWeight(head ? .semibold : .regular)
                .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
        }
        .frame(width: width, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
        // One element per cell, so VoiceOver reads a cell at a time and the first
        // heading cell can name the table from outside.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(head && column == 0 ? "talk.table" : "talk.cell")
    }
}
private struct TalkCodeAttribute: TextAttribute {}
private struct TalkInlineRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[TalkCodeAttribute.self] != nil {
                    let rect = run.typographicBounds.rect.insetBy(dx: -1, dy: 0)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(uiColor: .tertiarySystemFill)))
                }
                context.draw(run)
            }
        }
    }
}
struct TalkInlineText: View {
    let text: String
    var style: Font.TextStyle = .subheadline
    private var rendered: Text {
        let value = TalkMarkdown.inline(text)
        return value.runs.reduce(Text("")) { partial, run in
            var piece = Text(AttributedString(value[run.range]))
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece = piece.font(.system(.footnote, design: .monospaced)).customAttribute(TalkCodeAttribute())
            }
            return Text("\(partial)\(piece)")
        }
    }
    var body: some View {
        rendered.font(.system(style)).lineSpacing(PocketType.lineSpacing).textRenderer(TalkInlineRenderer())
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
