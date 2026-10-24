import SwiftUI
import Observation

@MainActor @Observable final class DocReaderState {
    var showTOC = false; var showText = false; var showFind = false; var showRaw = false; var ask = false; var wrap = true
    var query = ""; var matches: [Int] = []; var matchIndex = 0; var scrollTo: Int?
    static let titles = ["小","標準","大","特大","最大"]
    static let factors = [0.85,1.0,1.15,1.3,1.5]
    func search(_ blocks: [DocMarkdownBlock]) {
        matches = []
        guard !query.isEmpty else { matchIndex = 0; return }
        for block in blocks {
            var remaining = block.text[...]
            while let range = remaining.range(of: query,options:.caseInsensitive) {
                matches.append(block.id); remaining = remaining[range.upperBound...]
            }
        }
        matchIndex = 0; scrollTo = matches.first
    }
    func move(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + direction + matches.count) % matches.count; scrollTo = matches[matchIndex]
    }
}
struct DocReaderTools: View {
    @Bindable var state: DocReaderState
    @Binding var textSize: Int
    let document: DocMarkdownDocument?
    var code = false
    var body: some View {
        VStack(spacing: 8) {
            if state.showFind {
                HStack {
                    TextField("本文を探す",text:$state.query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("doc.find.input")
                    Text(state.matches.isEmpty ? "0/0" : "\(state.matchIndex + 1)/\(state.matches.count)").monospacedDigit().font(.caption).accessibilityIdentifier("doc.find.count")
                    Button { state.move(-1) } label: { Image(systemName:"chevron.up") }.accessibilityIdentifier("doc.find.previous").accessibilityLabel("前の一致")
                    Button { state.move(1) } label: { Image(systemName:"chevron.down") }.accessibilityIdentifier("doc.find.next").accessibilityLabel("次の一致")
                    Button { state.showFind = false } label: { Image(systemName:"xmark") }.accessibilityLabel("検索を閉じる")
                }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)).padding(.horizontal,12)
            }
            HStack(spacing: 24) {
                if code {
                    tool("検索","magnifyingglass","doc.find") { state.showFind.toggle() }
                    tool("折り返し","text.word.spacing","viewer.wrap") { state.wrap.toggle() }
                } else {
                    tool("目次","list.bullet","doc.toc") { state.showTOC = true }
                }
                tool("文字","textformat.size","doc.text") { state.showText = true }
                if !code { tool("検索","magnifyingglass","doc.find") { state.showFind.toggle() } }
                tool("聞く","text.bubble","doc.ask") { state.ask.toggle() }
            }.padding(.horizontal,28).padding(.vertical,10).background(.regularMaterial,in:Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.08),lineWidth:1))
        }.padding(.bottom,6)
        .sheet(isPresented:$state.showTOC) {
            NavigationStack {
                List(document?.headings ?? []) { heading in
                    Button { state.scrollTo = heading.id; state.showTOC = false } label: {
                        Text(heading.inline).padding(.leading, heading.kind == .heading(3) ? 16 : 0)
                    }.accessibilityIdentifier("doc.toc.\(heading.id)")
                }.navigationTitle("目次").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("閉じる") { state.showTOC = false } } }
            }.presentationDetents([.medium,.large])
        }
        .sheet(isPresented:$state.showText) {
            NavigationStack {
                List(0..<5,id:\.self) { index in
                    Button { textSize = index; state.showText = false } label: {
                        HStack { Text(DocReaderState.titles[index]); Spacer(); if textSize == index { Image(systemName:"checkmark") } }
                    }.accessibilityIdentifier("doc.text.\(index)")
                }.navigationTitle("文字の大きさ").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("閉じる") { state.showText = false } } }
            }.presentationDetents([.medium])
        }
    }
    private func tool(_ title: String,_ symbol: String,_ id: String, action:@escaping ()->Void)->some View {
        Button(action:action) {
            VStack(spacing:4) { Image(systemName:symbol).font(.system(size:19)); Text(title).font(.system(size:10)) }
        }.buttonStyle(.plain).foregroundStyle(id == "doc.ask" ? Color("Accent") : .primary)
            .accessibilityIdentifier(id).accessibilityLabel(title).accessibilityValue(id == "doc.text" ? DocReaderState.titles[min(4,max(0,textSize))] : id == "viewer.wrap" ? (state.wrap ? "オン" : "オフ") : "")
    }
}
struct DocReaderDebug: View {
    var document:DocMarkdownDocument? = nil
    @State private var metrics = DocViewerMetrics.shared
    var body: some View {
        if SkillShelfStubFixture.active && TalkLaunch.evidenceFlag("-PocketMeasure") {
            Text(metrics.debug + (document.map { " lastBlock=\($0.blocks.last?.id ?? 0)" } ?? "")).font(.system(size:8)).padding(2).background(.regularMaterial).accessibilityIdentifier("viewer.debug").allowsHitTesting(false)
        }
    }
}
