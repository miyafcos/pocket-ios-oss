import SwiftUI
import Observation

enum SkillShareFault {
    static func message(_ data:Data,status:Int)->String {
        let body = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        switch status {
        case 413:
            let files = body["files"] as? Int ?? 0, size = body["size"] as? Int ?? 0
            let maxFiles = body["maxFiles"] as? Int ?? 5000, maxSize = body["maxSize"] as? Int ?? 52_428_800
            return "大きすぎます (\(files) 件・\(FileOpen.size(size))／上限 \(maxFiles) 件・\(FileOpen.size(maxSize)))"
        case 404: return "このスキルのファイルが見つかりません。"
        case 400: return "共有する組み合わせを確認してください。"
        case 403: return "この場所は共有できない設定です。"
        case 503: return "スキルを準備しています。少し待って、もう一度お試しください。"
        default: return "共有の準備ができませんでした (HTTP \(status))。"
        }
    }
}
private final class SkillShareProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update:@Sendable (Double)->Void
    init(_ update:@escaping @Sendable (Double)->Void) { self.update = update }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesExpectedToWrite > 0 { update(Double(totalBytesWritten)/Double(totalBytesExpectedToWrite)) }
    }
}
@MainActor @Observable final class SkillShareDownload {
    private(set) var busy = false; private(set) var progress:Double?; private(set) var failure:String?
    private(set) var item:DocViewerShareItem?
    private var task:Task<Void,Never>?
    private var generation = UUID()
    func clearItem() { item = nil }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false; progress = nil }
    func start(url:URL,name:String) {
        guard !busy else { return }
        busy = true; failure = nil; progress = nil; generation = UUID()
        let current = generation
        task = Task {
            defer { if generation == current { busy = false } }
            do {
                let data:Data; let response:HTTPURLResponse
                if SkillShelfStubFixture.active {
                    (data,response) = try await DocViewerTransfer.get(url)
                } else {
                    let delegate = SkillShareProgress { [weak self] fraction in Task { @MainActor in if self?.generation == current { self?.progress = fraction } } }
                    let (temporary,raw) = try await DocViewerTransfer.session.download(for:PocketDevice.request(URLRequest(url:url)),delegate:delegate)
                    guard let http = raw as? HTTPURLResponse else { throw ClientError.invalidResponse }
                    response = http; data = try await Task.detached { try Data(contentsOf:temporary) }.value
                }
                try Task.checkCancellation()
                guard response.statusCode == 200 else { failure = SkillShareFault.message(data,status:response.statusCode); return }
                progress = 1
                let local = try await DocViewerTransfer.save(data,name:name)
                guard !Task.isCancelled, generation == current else {
                    await DocViewerTransfer.removeTemporaryShare(local); return
                }
                item = .init(url:local)
            } catch {
                if !Task.isCancelled && generation == current { failure = "つながりませんでした。" + error.localizedDescription }
            }
        }
    }
}
struct SkillShareScreen: View {
    let skill:ShelfSkill
    let base:String
    var initial:SkillFilesPayload?
    @Environment(\.dismiss) private var dismiss
    @State private var payload:SkillFilesPayload?
    @State private var failure:String?
    @State private var selection = SkillShareSelection()
    @State private var download = SkillShareDownload()
    init(skill:ShelfSkill,base:String,initial:SkillFilesPayload?) {
        self.skill = skill; self.base = base; self.initial = initial
        _payload = State(initialValue:initial)
    }
    private var single:Bool { payload?.single ?? (skill.kind == "command") }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if single {
                        Text("このコマンドのファイルを共有").font(.headline)
                        Button("このコマンドのファイルを共有") { shareDocument() }.buttonStyle(.borderedProminent).frame(maxWidth:.infinity).accessibilityIdentifier("share.skillmd")
                    } else if let payload {
                        plan(payload.share)
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary).accessibilityIdentifier("share.error")
                        Button("もう一度") { Task { await load() } }
                    } else { ProgressView("共有するファイルを読み込んでいます") }
                    if download.busy {
                        VStack(spacing:10) {
                            if let progress = download.progress { ProgressView(value:progress) } else { ProgressView("取り込んでいます") }
                            Button("やめる") { download.cancel() }.accessibilityIdentifier("share.cancel")
                        }.frame(maxWidth:.infinity)
                    }
                    if let error = download.failure { Text(error).font(.callout).foregroundStyle(.orange).accessibilityIdentifier("share.error") }
                    if SkillShelfStubFixture.active && TalkLaunch.evidenceFlag("-PocketMeasure") {
                        Text(SkillShelfStubFixture.zipDebug).font(.system(size:8)).accessibilityIdentifier("share.stub.request")
                    }
                }.padding(16)
            }.accessibilityIdentifier("share.sheet")
                .navigationTitle("スキルを共有").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button { dismiss() } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("閉じる") } }
                .task { await load() }
                .background(DocViewerShareAnchor(url:download.item?.url,completed:{ download.clearItem() }))
                .onDisappear { download.cancel() }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private func plan(_ plan:SkillSharePlan)->some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:12) {
                Image(systemName:"doc.zipper").font(.system(size:28)).foregroundStyle(Color("Accent")).frame(width:52,height:56).background(Color("Accent").opacity(0.13),in:RoundedRectangle(cornerRadius:14))
                VStack(alignment:.leading,spacing:5) {
                    Text(plan.zipName).font(.headline)
                    Text(selection.totalsLabel(plan)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("share.totals")
                }
            }
            Text("入れるもの").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing:0) {
                ForEach(plan.include) { item in
                    Button { selection.toggle(item) } label: {
                        HStack(spacing:10) {
                            Image(systemName:item.required ? "lock.fill" : selection.off.contains(item.key) ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(item.required ? Color.secondary : selection.off.contains(item.key) ? Color.secondary : Color("Accent"))
                            Image(systemName:item.dir ? "folder" : "doc.text").foregroundStyle(.secondary)
                            Text(item.key + (item.dir ? "/" : "")).font(.callout).lineLimit(2)
                            Spacer(minLength:4)
                            Text(item.dir ? "\(item.files) ファイル · \(FileOpen.size(item.size))" : FileOpen.size(item.size)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }.padding(12).frame(maxWidth:.infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(item.required || download.busy).accessibilityIdentifier("share.include." + item.key)
                    Divider().padding(.leading,42)
                }
            }.background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
            if !plan.exclude.isEmpty {
                Text("外すもの　押すと入れられます").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing:0) {
                    ForEach(plan.exclude) { group in
                        Button { selection.toggle(group) } label: { groupRow(group,locked:false) }
                            .buttonStyle(.plain).disabled(download.busy).accessibilityIdentifier("share.exclude." + group.reason)
                        Divider().padding(.leading,42)
                    }
                }.background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
            }
            if !plan.never.isEmpty {
                VStack(spacing:0) {
                    ForEach(plan.never) { group in
                        Button {} label: { groupRow(group,locked:true) }.buttonStyle(.plain).disabled(true).accessibilityIdentifier("share.never." + group.reason)
                    }
                }.foregroundStyle(.secondary).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
            }
            Label("鍵の印の付いたものと、.env・credentials・鍵のファイルは入りません。",systemImage:"lock.fill").font(.caption).foregroundStyle(.secondary)
            if selection.hasUnresolvedOverlap(plan) {
                Text("選択したフォルダ内の除外分は、取り込み時に差し引かれます。").font(.caption).foregroundStyle(.secondary)
            }
            if selection.exceeds(plan) {
                Text("上限は \(plan.limits.files) ファイル・\(FileOpen.size(plan.limits.bytes)) です。入れるものを減らしてください。").font(.caption).foregroundStyle(.orange)
            }
            Button {
                do { download.start(url:try selection.url(base:base,id:skill.id),name:plan.zipName) }
                catch { failure = "このスキルの場所を開けません。" }
            } label: { Label("zip にして共有…",systemImage:"square.and.arrow.up").font(.headline).frame(maxWidth:.infinity).padding(14).foregroundStyle(.white).background(Color("Accent"),in:RoundedRectangle(cornerRadius:14)) }
                .buttonStyle(.plain).disabled(selection.exceeds(plan) || download.busy).accessibilityIdentifier("share.zip")
            Button("SKILL.md だけ共有") { shareDocument() }.font(.callout).frame(maxWidth:.infinity).padding(14).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:14))
                .buttonStyle(.plain).disabled(download.busy).accessibilityIdentifier("share.skillmd")
        }
    }
    private func groupRow(_ group:SkillShareGroup,locked:Bool)->some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:locked ? "lock.fill" : selection.on.contains(group.reason) ? "checkmark.circle.fill" : "circle").foregroundStyle(selection.on.contains(group.reason) && !locked ? Color("Accent") : .secondary)
            VStack(alignment:.leading,spacing:4) {
                Text(group.title).font(.callout)
                Text(group.paths.joined(separator:"・") + (group.more > 0 ? "・ほか \(group.more)" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength:4)
            Text("\(group.files) ファイル · \(FileOpen.size(group.size))").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.padding(12).frame(maxWidth:.infinity).contentShape(Rectangle())
    }
    private func load() async {
        guard payload == nil, !single else { return }
        do { payload = try await TalkReadClient(base:base,session:DocViewerTransfer.session).get("skills/files",query:[.init(name:"id",value:skill.id)]); failure = nil }
        catch { failure = "共有するファイルを読めませんでした。" }
    }
    private func shareDocument() {
        guard let path = skill.docPath, let url = FileOpen.contentURL(base:base,path:path) else { failure = "説明書の場所がありません。"; return }
        download.start(url:url,name:single ? FileOpen.name(path) : "SKILL.md")
    }
}
