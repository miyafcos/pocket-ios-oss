import SwiftUI

struct SkillCurationBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(Color("Accent"))
            .background(Color("Accent").opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct SkillSuggestBanner: View {
    let count: Int
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color("Accent"))
                Text("名前と絵がまだのスキル \(count) 本").lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text("整える ›").foregroundStyle(Color("Accent")).fixedSize()
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 12)
                .background(Color("Accent").opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityIdentifier("skills.new.banner")
            .accessibilityLabel("名前と絵がまだのスキル \(count) 本、整える")
    }
}

struct SkillSuggestSheet: View {
    @Bindable var store: SkillShelfStore
    @State private var model: SkillSuggestModel
    @Environment(\.dismiss) private var dismiss
    init(store: SkillShelfStore) {
        self.store = store
        _model = State(initialValue: SkillSuggestModel(base: store.base, onDone: { await store.refresh() }))
    }
    private var payload: SkillShelfPayload { store.index?.payload ?? .init() }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Codex が名前・棚・1 行の説明・絵の案を作ります。送るのはスキルの説明と SKILL.md の先頭だけです。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !payload.guessSkills.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(payload.guessSkills) { skill in item(skill, badge: "推定") }
                        }
                    }
                    if !payload.autoSkills.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Codex の案のもの").font(.subheadline.weight(.semibold))
                            ForEach(payload.autoSkills) { skill in item(skill, badge: "AI 案") }
                        }
                    }
                    if model.restoring { ProgressView("状態を確かめています") }
                    Button { model.run() } label: {
                        Text("Codex に整えてもらう").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(Color("Accent"))
                        .disabled(model.busy || payload.guessSkills.isEmpty)
                        .accessibilityIdentifier("skills.new.run")
                    if model.status?.state == .running, model.error == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                ProgressView()
                                Text(model.progress).accessibilityIdentifier("skills.new.progress")
                            }
                            Text("閉じても PC で続きます").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .contain)
                    }
                    if let result = model.result {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(result).font(.headline).accessibilityIdentifier("skills.new.result")
                            ForEach(Array((model.status?.rejected ?? []).enumerated()), id: \.offset) { _, rejection in
                                Text(rejection.id + " · " + SkillSuggestCopy.rejection(rejection.reason))
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let error = model.error {
                        Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("skills.new.error")
                    }
                    if !payload.autoSkills.isEmpty {
                        Button("案を作り直す") { model.run(redo: true) }
                            .font(.caption).disabled(model.busy)
                            .accessibilityIdentifier("skills.new.redo")
                    }
                }.padding(20)
            }.accessibilityIdentifier("skills.new.sheet")
                .navigationTitle("新しいスキル").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { dismiss() }.accessibilityIdentifier("skills.new.close")
                    }
                }
        }.task { model.open() }.onDisappear { model.stop() }
    }
    private func item(_ skill: ShelfSkill, badge: String) -> some View {
        let category = payload.categories.first { $0.id == skill.category } ?? SkillCategory(id: skill.category)
        return HStack(spacing: 12) {
            SkillShelfIcon(skill: skill, category: category)
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.label).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(category.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            SkillCurationBadge(text: badge)
        }.padding(.vertical, 7).accessibilityElement(children: .combine)
            .accessibilityIdentifier("skills.new.item." + skill.id)
    }
}
