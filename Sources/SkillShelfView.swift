import SwiftUI
import UIKit

extension SkillCategory {
    var tint: Color {
        let raw = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, let hex = UInt32(raw, radix: 16) else { return Color(uiColor: .systemGray) }
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    var validSymbol: String { UIImage(systemName: symbol) == nil ? "square.grid.2x2" : symbol }
}

struct SkillShelfAgentMark: View {
    let agent: String
    var size: CGFloat = 11
    var body: some View {
        Group {
            if agent == "claude" { SkillSymbolClaudeMark().stroke(style:StrokeStyle(lineWidth:size * 0.14,lineCap:.round)).foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34)) }
            else { SkillSymbolHexagonMark().stroke(style:StrokeStyle(lineWidth:size * 0.11,lineJoin:.round)).foregroundStyle(.blue) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct SkillShelfIcon: View {
    let skill: ShelfSkill
    let category: SkillCategory
    var size: CGFloat = 38
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var scale
    var body: some View {
        Group {
            if let image = SkillShelfArtwork.image(skill: skill, category: category, size: size, scale: scale, scheme: colorScheme, contrast: contrast) {
                Image(uiImage: image).renderingMode(.original).resizable().frame(width: size, height: size)
            } else { SkillShelfIconArtwork(skill: skill, category: category, size: size) }
        }.frame(width: size, height: size).accessibilityHidden(true).onAppear { SkillShelfArtwork.appeared() }
    }
}
struct SkillShelfIconArtwork: View {
    let skill: ShelfSkill
    let category: SkillCategory
    var size: CGFloat = 38
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        ZStack {
            if skill.isOwn {
                shape.fill(LinearGradient(colors: [category.tint.mix(with: .white, by: 0.18), category.tint.mix(with: .black, by: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                shape.fill(category.tint.opacity(0.17))
                shape.strokeBorder(category.tint.opacity(0.55), lineWidth: 1.3)
            }
            Image(uiImage: SkillSymbol.image(SkillSymbol.name(skill: skill, category: category)) ?? UIImage())
                .renderingMode(.template).resizable().scaledToFit().frame(width: size * 0.56, height: size * 0.56)
                .foregroundStyle(skill.isOwn ? Color.white : category.tint)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct SkillShelfCategoryMark: View {
    let category: SkillCategory
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: category.validSymbol).font(.system(size: size * 0.64, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(category.tint, in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

struct SkillShelfScreen: View {
    @State private var store: SkillShelfStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @State private var query = ""
    @State private var filter = SkillShelfFilter.all
    @State private var expanded = Set<String>()
    @State private var selected: ShelfSkill?
    @State private var showNewSkills = false
    @GestureState private var touching = false
    @State private var scrolling = false
    @State private var firstSkeletonPainted = false
    @State private var metrics = SkillShelfMetrics.shared
    init(base: String) {
        SkillShelfMetrics.shared.checkpoint("initStart")
        let directory = SkillShelfStubFixture.cacheDirectory
        SkillShelfStubFixture.prepare(base: base, directory: directory)
        _store = State(initialValue: SkillShelfStore(base: base, directory: directory))
        SkillShelfMetrics.shared.checkpoint("initEnd")
    }
    private var mode: SkillShelfMode { .list }
    private var snapshot: SkillShelfSnapshot? { store.index?.snapshot(query: query, filter: filter, pins: store.preferences.pins, mode: mode) }
    var body: some View {
        let token = SkillShelfProfile.begin("ScreenBody")
        defer { SkillShelfProfile.end(token) }
        return Group {
            if store.index == nil && store.error == nil && !firstSkeletonPainted {
                // Paint the empty shelf before constructing a scroll reader, a
                // search field, network machinery or the populated row tree.
                VStack(spacing:12) {
                    SkillShelfLoadingControls().frame(height:78).accessibilityHidden(true)
                    skeleton
                }.padding(.horizontal,12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                    .background(Color(uiColor:.systemGroupedBackground))
            } else { populated }
        }
        .navigationTitle("スキル").navigationBarTitleDisplayMode(.large)
        .onChange(of: selected) { _, _ in updateInteraction() }
        .navigationDestination(item: $selected) { skill in
            SkillPageScreen(skill: skill, payload: store.index?.payload ?? SkillShelfPayload(), preferences: store.preferences, base: store.base)
        }
        .sheet(isPresented: $showNewSkills) { SkillSuggestSheet(store: store) }
        .overlay(alignment: .bottomLeading) {
            if selected == nil && SkillShelfStubFixture.active && TalkLaunch.evidenceFlag("-PocketMeasure") {
                SkillShelfDebugView()
            }
        }
        .task(id:firstSkeletonPainted) {
            if store.index != nil || firstSkeletonPainted {
                metrics.checkpoint("refreshStart"); await store.refresh()
            }
        }
        .onAppear { if store.index != nil { metrics.startWatching() } }
        .onChange(of:firstSkeletonPainted) { _,painted in if painted { metrics.startWatching() } }
        .onDisappear { store.setListInteracting(false); SkillShelfArtwork.setInteracting(false); metrics.stopWatching() }
    }
    private var populated: some View {
        ScrollViewReader { proxy in
            ScrollView {
                shelfStack {
                    if store.index == nil && store.error == nil && !firstSkeletonPainted {
                        SkillShelfLoadingControls().frame(height:78).accessibilityHidden(true)
                    } else { controls(counts: snapshot?.counts ?? [:]) }
                    if let count = store.index?.payload.guessSkills.count, count > 0 {
                        SkillSuggestBanner(count: count) { showNewSkills = true }
                    }
                    if let error = store.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).foregroundStyle(.secondary).accessibilityIdentifier("skills.error")
                            Button("もう一度") { Task { await store.refresh() } }.accessibilityIdentifier("skills.retry")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    if let snapshot {
                        categoryChips(snapshot, proxy: proxy)
                        if !snapshot.frequent.isEmpty {
                            section(category: SkillCategory(id: "frequent", name: "よく使う", color: "#FFB800", symbol: "star.fill"),
                                    skills: snapshot.frequent, total: snapshot.frequent.count, frequent: true)
                                .id("frequent")
                        }
                        ForEach(snapshot.sections) { shelf in
                            let skills = shelf.visible(mode: mode, expanded: expanded.contains(shelf.id))
                            let remaining = shelf.remaining(mode: mode, expanded: expanded.contains(shelf.id))
                            SkillShelfDeferredContent(
                                initiallyVisible: typeSize != .large || shelf.id == snapshot.sections.first?.id ||
                                    (snapshot.frequent.isEmpty && shelf.id == snapshot.sections.dropFirst().first?.id),
                                height: SkillShelfLayout.height(count: skills.count, mode: mode, remaining: remaining,
                                                                frequent: false, scale: displayScale)) {
                                section(category: shelf.category, skills: skills, total: shelf.skills.count, remaining: remaining)
                            }.id(shelf.id)
                        }
                        if snapshot.sections.isEmpty {
                            Text("見つかりませんでした").foregroundStyle(.secondary).padding(24)
                                .accessibilityIdentifier("skills.empty")
                                .background { if SkillShelfStubFixture.empty { SkillShelfPaintProbe(kind: .empty, cached: store.fromCache) } }
                        }
                        Text("オレンジの印＝Claude・青の印＝Codex で使えます")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    } else if store.error == nil { skeleton }
                }.padding(.horizontal, 12).padding(.bottom, 24)
            }.accessibilityIdentifier("skills.scroll")
                .background(Color(uiColor: .systemGroupedBackground))
                .onScrollPhaseChange { _, phase in scrolling = phase != .idle; updateInteraction() }
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($touching) { _, state, _ in state = true })
                .onChange(of: touching) { _, _ in updateInteraction() }
        }
    }


    @ViewBuilder private func shelfStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if store.index == nil {
            // The first-load placeholders have only two children. Lay them
            // out immediately; virtualize the populated shelves below.
            VStack(spacing: 12) { content() }
        } else { LazyVStack(spacing: 12) { content() } }
    }
    private func updateInteraction() {
        store.setListInteracting(touching || scrolling || selected != nil)
        SkillShelfArtwork.setInteracting(touching || scrolling || selected != nil)
    }
    private func controls(counts: [SkillShelfFilter: Int]) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("スキルを探す", text: $query).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("skills.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("検索を消す").accessibilityIdentifier("skills.search.clear")
                }
            }.padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            HStack(spacing: 5) {
                ForEach(SkillShelfFilter.allCases) { item in
                    Button { filter = item } label: {
                        Text("\(item.title) \(counts[item] ?? 0)").font(.system(size: 13, weight: filter == item ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.75).padding(.vertical, 6).frame(maxWidth: .infinity)
                            .foregroundStyle(filter == item ? Color(uiColor: .systemBackground) : .secondary)
                            .background(filter == item ? Color.primary : Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("skills.filter." + item.rawValue)
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        }.padding(.bottom, 2)
    }
    private func categoryChips(_ snapshot: SkillShelfSnapshot, proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button("よく使う") { proxy.scrollTo("frequent", anchor: .top) }
                    .padding(.horizontal, 11).padding(.vertical, 6).background(Color.yellow, in: Capsule()).foregroundStyle(.black)
                ForEach(snapshot.sections) { shelf in
                    Button("\(shelf.category.name) \(shelf.skills.count)") { proxy.scrollTo(shelf.id, anchor: .top) }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                        .accessibilityIdentifier("skills.category." + shelf.id)
                }
            }.font(.caption).buttonStyle(.plain)
        }
    }
    private func section(category: SkillCategory, skills: [ShelfSkill], total: Int, remaining: Int = 0, frequent: Bool = false) -> some View {
        let token = SkillShelfProfile.begin("SectionBuild")
        defer { SkillShelfProfile.end(token) }
        SkillShelfProfile.section(category.id)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                SkillShelfCategoryMark(category: category)
                Text(category.name).font(.headline)
                Text(frequent ? "使った回数の順" : "\(total)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 6).padding(.bottom, 9)
            LazyVStack(spacing: 0) {
                ForEach(Array(skills.enumerated()), id: \.element.id) { offset, skill in
                    if offset > 0 { Divider().padding(.leading, 64) }
                    row(skill).background { if frequent && offset == 0 { SkillShelfPaintProbe(kind: .tile, cached: store.fromCache) } }
                }
            }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            if remaining > 0 {
                Button("ほか \(remaining) 本 ›") { expanded.insert(category.id) }.font(.subheadline)
                    .foregroundStyle(Color("Accent")).frame(maxWidth: .infinity).padding(.top, 7).padding(.bottom, 2)
                    .accessibilityIdentifier("skills.more." + category.id)
            }
        }
    }
    private func row(_ skill: ShelfSkill) -> some View {
        let category = store.index?.category(for: skill) ?? SkillCategory(id: skill.category)
        return Button {
            DocViewerMetrics.shared.begin("page")
            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
            withTransaction(transaction) { selected = skill }
        } label: {
            HStack(spacing: 12) {
                SkillShelfIcon(skill: skill, category: category, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(skill.label).font(.subheadline.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        if skill.curation == "guess" {
                            SkillCurationBadge(text: "新").accessibilityIdentifier("skills.row." + skill.id + ".new")
                        }
                        Spacer(minLength: 0)
                        Text("\(skill.usageCount) 回").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing:2) {
                            if skill.agents.contains("claude") { SkillShelfAgentMark(agent:"claude") }
                            if skill.agents.contains("codex") { SkillShelfAgentMark(agent:"codex") }
                        }
                    }
                    Text(skill.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10).foregroundStyle(.primary).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("skills.row." + skill.id)
            .accessibilityLabel(SkillShelfStyle.accessibility(skill, category: category))
    }
    private var skeleton: some View {
        SkillShelfSkeleton().frame(height: 218).padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityLabel("スキルの棚を読み込んでいます").accessibilityIdentifier("skills.skeleton")
            .background(SkillShelfPaintProbe(kind: .skeleton, cached: false,onPaint:{ firstSkeletonPainted = true }))
    }

}

private struct SkillShelfDebugView: View {
    @State private var metrics = SkillShelfMetrics.shared
    var body: some View {
        // Rendering diagnostics is not part of the shelf. Defer its text and
        // blur setup until the unchanged visible-two-frame probe has fired.
        if metrics.paintMS >= 0 || metrics.skeletonMS >= 0 {
            Text(metrics.debug).font(.system(size:8)).padding(2).background(.regularMaterial)
                .accessibilityIdentifier("skills.debug").allowsHitTesting(false)
        }
    }
}
