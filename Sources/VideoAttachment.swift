import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

enum VideoAttachmentError: LocalizedError, Equatable {
    case unreadable, unsupported, cannotRemux, tooLarge, upload(Int)
    var errorDescription: String? {
        switch self {
        case .unreadable: "動画を読み込めませんでした。もう一度選んでください。"
        case .unsupported: "この動画は MP4 に変換できませんでした。"
        case .cannotRemux: "この動画は画質を保ったまま MP4 にできません。別の動画を選んでください。"
        case .tooLarge: "動画が大きすぎて送れません（変換後 200 MB まで）。"
        case .upload(let status): "動画を送れませんでした（HTTP \(status)）。もう一度選んでください。"
        }
    }
}

struct VideoPreview: Equatable, Sendable {
    var thumbnail: Data?
    var duration: Double
    var bytes: Int
    var durationLabel: String {
        let seconds = Int(max(0, duration.isFinite ? duration : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var sizeLabel: String { String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
}

struct PreparedVideo: Sendable {
    let url: URL
    let preview: VideoPreview
    let renderSize: CGSize
    let reencoded: Bool
}

enum VideoAttachment {
    static let maxDimension: CGFloat = 1600
    static let maxBytes = 200 * 1024 * 1024
    static let thumbnailSide: CGFloat = 120
    static let progressInterval: TimeInterval = 0.25

    struct Geometry: Equatable {
        let renderSize: CGSize
        let transform: CGAffineTransform
        let reencode: Bool
    }

    static func geometry(naturalSize: CGSize, preferredTransform: CGAffineTransform) throws -> Geometry {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
        let longest = max(rect.width, rect.height)
        guard longest.isFinite, rect.width > 0, rect.height > 0 else { throw VideoAttachmentError.unreadable }
        guard longest > maxDimension else {
            return Geometry(renderSize: rect.size, transform: preferredTransform, reencode: false)
        }
        let scale = maxDimension / longest
        // Keep a uniform scale. Even pixel padding avoids cropping a fractional edge.
        let size = CGSize(width: min(maxDimension, ceil(rect.width * scale / 2) * 2),
                          height: min(maxDimension, ceil(rect.height * scale / 2) * 2))
        let transform = preferredTransform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return Geometry(renderSize: size, transform: transform, reencode: true)
    }

    static func validate(bytes: Int) throws {
        guard bytes <= maxBytes else { throw VideoAttachmentError.tooLarge }
        guard bytes > 0 else { throw VideoAttachmentError.unreadable }
    }
    static func byteCount(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    static func isMP4(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        let brands = ["isom", "iso2", "mp41", "mp42", "avc1", "hvc1", "mp4v", "M4V "]
        return prefix.count == 12 && String(data: prefix[4..<8], encoding: .ascii) == "ftyp"
            && brands.contains(String(data: prefix[8..<12], encoding: .ascii) ?? "")
    }
    static func temporaryURL(extension suffix: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pocket-video-\(UUID().uuidString).\(suffix)")
    }
    static func copyToTemporary(_ source: URL) throws -> URL {
        guard source.isFileURL else { throw VideoAttachmentError.unreadable }
        let target = temporaryURL(extension: source.pathExtension.lowercased() == "mov" ? "mov" : "mp4")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
    static func removeTemporary(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              url.lastPathComponent.hasPrefix("pocket-video-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Only the export path changes pixels. A smaller MP4 is copied verbatim;
    /// a smaller MOV is remuxed with its original track transform and codec.
    static func prepare(_ source: URL) async throws -> PreparedVideo {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoAttachmentError.unreadable
        }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let dimensions = try geometry(naturalSize: natural, preferredTransform: preferred)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw VideoAttachmentError.unreadable }
        let output: URL
        if !dimensions.reencode, try isMP4(source) {
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first,
                  [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(CMFormatDescriptionGetMediaSubType(format)) else {
                throw VideoAttachmentError.cannotRemux
            }
            try validate(bytes: byteCount(source))
            output = try copyToTemporary(source)
        } else {
            output = temporaryURL()
            do {
                let preset = dimensions.reencode ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
                guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
                      exporter.supportedFileTypes.contains(.mp4) else {
                    throw dimensions.reencode ? VideoAttachmentError.unsupported : VideoAttachmentError.cannotRemux
                }
                if dimensions.reencode {
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    layer.setTransform(dimensions.transform, at: .zero)
                    instruction.layerInstructions = [layer]
                    let composition = AVMutableVideoComposition()
                    composition.renderSize = dimensions.renderSize
                    let rate = try await track.load(.nominalFrameRate)
                    composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(60, rate.rounded()))))
                    composition.instructions = [instruction]
                    exporter.videoComposition = composition
                }
                exporter.shouldOptimizeForNetworkUse = true
                try await exporter.export(to: output, as: .mp4)
            } catch {
                removeTemporary(output)
                if error is CancellationError { throw error }
                if let known = error as? VideoAttachmentError { throw known }
                throw dimensions.reencode ? VideoAttachmentError.unsupported : VideoAttachmentError.cannotRemux
            }
        }
        do {
            let bytes = try byteCount(output)
            try validate(bytes: bytes)
            guard try isMP4(output) else { throw VideoAttachmentError.unsupported }
            let rendered = AVURLAsset(url: output)
            guard let outputTrack = try await rendered.loadTracks(withMediaType: .video).first,
                  let format = try await outputTrack.load(.formatDescriptions).first,
                  [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(CMFormatDescriptionGetMediaSubType(format)) else {
                throw VideoAttachmentError.cannotRemux
            }
            let generator = AVAssetImageGenerator(asset: rendered)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: thumbnailSide * 2, height: thumbnailSide * 2)
            let image = try await generator.image(at: .zero).image
            let thumbnail = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
            return PreparedVideo(url: output, preview: VideoPreview(thumbnail: thumbnail, duration: duration.seconds, bytes: bytes),
                                 renderSize: dimensions.renderSize, reencoded: dimensions.reencode)
        } catch {
            removeTemporary(output)
            throw error
        }
    }
}

/// Providers give temporary URLs that disappear when their callback returns.
final class VideoSelection: @unchecked Sendable {
    private let provider: NSItemProvider?
    private let file: URL?
    init(provider: NSItemProvider) { self.provider = provider; file = nil }
    init(file: URL) { self.file = file; provider = nil }

    func copyFile() async throws -> URL {
        if let file { return try VideoAttachment.copyToTemporary(file) }
        guard let provider else { throw VideoAttachmentError.unreadable }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                do {
                    guard let url else { throw error ?? VideoAttachmentError.unreadable }
                    continuation.resume(returning: try VideoAttachment.copyToTemporary(url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

final class VideoUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let sent = OSAllocatedUnfairLock(initialState: 0.0)
    var fraction: Double { sent.withLock { $0 } }
    func reset() { sent.withLock { $0 = 0 } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        sent.withLock { $0 = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct VideoUploadClient: Sendable {
    let base: String
    let session: URLSession
    let dryRun: Bool

    func upload(_ video: PreparedVideo, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        let bytes = try VideoAttachment.byteCount(video.url)
        try VideoAttachment.validate(bytes: bytes)
        var request = try TalkReadClient(base: base).request("upload/stream")
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(bytes), forHTTPHeaderField: "Content-Length")
        request.setValue(try PocketCSRF.origin(base), forHTTPHeaderField: "Origin")
        if dryRun {
            request.setValue("YES", forHTTPHeaderField: "X-Pocket-Native-Dry")
            request.setValue("native-dry-only", forHTTPHeaderField: "X-Pocket-CSRF")
        } else {
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
        }
        let delegate = VideoUploadDelegate()
        let ticker = Task {
            while !Task.isCancelled {
                await progress(delegate.fraction)
                do { try await Task.sleep(for: .seconds(VideoAttachment.progressInterval)) } catch { return }
            }
        }
        defer { ticker.cancel() }
        var (data, response) = try await session.upload(for: request, fromFile: video.url, delegate: delegate)
        if !dryRun, (response as? HTTPURLResponse)?.statusCode == 403,
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String == "csrfDenied" {
            await PocketCSRF.shared.forget(base: base)
            request.setValue(try await PocketCSRF.shared.token(base: base, session: session), forHTTPHeaderField: "X-Pocket-CSRF")
            delegate.reset()
            (data, response) = try await session.upload(for: request, fromFile: video.url, delegate: delegate)
        }
        guard let response = response as? HTTPURLResponse else { throw VideoAttachmentError.unreadable }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 413 { throw VideoAttachmentError.tooLarge }
            throw VideoAttachmentError.upload(response.statusCode)
        }
        let result = try JSONDecoder().decode(TalkMutationResult.self, from: data)
        guard let path = result.path, !path.isEmpty else { throw TalkWriteError.uncertain }
        ticker.cancel()
        await ticker.value
        await progress(1)
        return path
    }
}

struct UploadedVideo: Identifiable, Equatable, Sendable {
    let id = UUID()
    let path: String
    let preview: VideoPreview
}

@MainActor @Observable final class VideoAttachments {
    private(set) var records: [UploadedVideo] = []
    private(set) var busy = false
    private(set) var progress: Double?
    private(set) var preview: VideoPreview?
    private(set) var failure: String?
    private(set) var revision = 0
    var isVisible: Bool { busy || !records.isEmpty || failure != nil }
    var hasPreview: Bool { preview != nil || !records.isEmpty }

    func attach(_ selection: VideoSelection, client: VideoUploadClient) async -> UploadedVideo? {
        guard !busy else { return nil }
        busy = true; failure = nil; progress = nil; revision += 1
        defer { busy = false; preview = nil; progress = nil; revision += 1 }
        do {
            let source = try await selection.copyFile()
            defer { VideoAttachment.removeTemporary(source) }
            let video = try await VideoAttachment.prepare(source)
            defer { VideoAttachment.removeTemporary(video.url) }
            preview = video.preview; progress = 0; revision += 1
            let path = try await client.upload(video) { [weak self] fraction in
                if self?.busy == true { self?.progress = fraction }
            }
            let record = UploadedVideo(path: path, preview: video.preview)
            records.append(record)
            return record
        } catch {
            failure = (error as? VideoAttachmentError)?.localizedDescription
                ?? "動画を添付できませんでした。もう一度選んでください。"
            return nil
        }
    }
    func remove(_ id: UUID) -> String? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        records.removeAll { $0.id == id }; revision += 1
        return record.path
    }
    func retain(in draft: String) {
        let kept = records.filter { TalkAttachmentLines.contains($0.path, in: draft) }
        if kept != records { records = kept; revision += 1 }
    }
}

struct VideoAttachmentStrip: View {
    let model: VideoAttachments
    let onRemove: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.hasPreview {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(model.records) { record in
                            chip(record.preview) { onRemove(record.id) }
                        }
                        if let preview = model.preview { chip(preview, remove: nil) }
                    }
                }
            }
            if model.busy {
                if let progress = model.progress {
                    ProgressView(value: progress) {
                        Text("動画を送っています \(Int(progress * 100))%").font(PocketType.meta)
                    }
                } else {
                    HStack { ProgressView(); Text("動画を準備しています").font(PocketType.meta) }
                }
            }
            if let failure = model.failure {
                Text(failure).font(PocketType.meta).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("video.attachments")
    }
    private func chip(_ preview: VideoPreview, remove: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let data = preview.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else { Color(uiColor: .tertiarySystemFill) }
            }
            .frame(width: VideoAttachment.thumbnailSide, height: VideoAttachment.thumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("添付した動画")
            .accessibilityIdentifier("video.thumbnail")
            .overlay(alignment: .topTrailing) {
                if let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65)).font(.system(size: 22))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("動画を外す")
                }
            }
            Text("\(preview.durationLabel)・\(preview.sizeLabel)")
                .font(PocketType.meta).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: VideoAttachment.thumbnailSide, alignment: .leading)
    }
}

struct VideoPicker: UIViewControllerRepresentable {
    let onSelect: (NSItemProvider) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos; config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            if let provider = results.first?.itemProvider { parent.onSelect(provider) }
        }
    }
}
