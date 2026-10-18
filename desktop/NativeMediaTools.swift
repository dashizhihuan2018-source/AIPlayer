import AppKit
import AVFoundation
import AVKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct GIFCaptureSettings: Equatable {
    let duration: Double
    let fps: Int
    var frameCount: Int { Int(ceil(duration * Double(fps))) }

    init?(duration: Double, fps: Int) {
        guard duration.isFinite, duration >= 0.2, duration <= 10, (1...30).contains(fps) else { return nil }
        self.duration = duration; self.fps = fps
    }
}

enum MediaToolError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum NativeToolDraftKind: String {
    case screenshot, gif, poster, recording
    var fileExtension: String { switch self { case .gif: return "gif"; case .recording: return "mp4"; default: return "png" } }
}

struct NativeClipRange: Equatable {
    let start: Double
    let end: Double
    init?(start: Double, end: Double, duration: Double) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0, duration <= 604_800,
              start >= 0, end <= duration, end - start >= 0.2 else { return nil }
        self.start = start; self.end = end
    }
}

final class NativeClipExporter {
    private let lock = NSLock()
    private var session: AVAssetExportSession?
    private var cancelled = false

    func start(source: URL, range: NativeClipRange, to output: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let asset = AVURLAsset(url: source)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough), export.supportedFileTypes.contains(.mp4) else {
                DispatchQueue.main.async { completion(.failure(MediaToolError.message("此媒体格式不支持本机 MP4 区间导出，原视频未改动"))) }; return
            }
            lock.lock(); session = export; let wasCancelled = cancelled; lock.unlock()
            guard !wasCancelled else { DispatchQueue.main.async { completion(.failure(MediaToolError.message("片段导出已取消"))) }; return }
            export.outputURL = output; export.outputFileType = .mp4
            export.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), end: CMTime(seconds: range.end, preferredTimescale: 600))
            export.shouldOptimizeForNetworkUse = true
            export.exportAsynchronously { [self] in
                lock.lock(); let wasCancelled = cancelled; session = nil; lock.unlock()
                let result: Result<Void, Error> = export.status == .completed && !wasCancelled ? .success(()) : .failure(MediaToolError.message(wasCancelled ? "片段导出已取消" : "此媒体无法导出为 MP4，原视频未改动"))
                DispatchQueue.main.async { completion(result) }
            }
            lock.lock(); let cancelledAfterStart = cancelled; lock.unlock()
            if cancelledAfterStart { export.cancelExport() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let session = session; lock.unlock()
        session?.cancelExport()
    }
}

final class NativeRecordingRangeController: NSWindowController, NSWindowDelegate {
    var onStart: ((NativeClipRange) -> Void)?
    var onClose: (() -> Void)?
    private let start: NSTextField
    private let end: NSTextField
    private let duration: Double
    private let status = NSTextField(wrappingLabelWithString: "导出所选片段为 MP4，播放状态和原文件保持不变。部分格式不支持。")
    private var closed = false

    init(position: Double, duration: Double) {
        self.duration = duration
        let from = max(0, min(position, duration - 0.2))
        start = NSTextField(string: String(format: "%.2f", from))
        end = NSTextField(string: String(format: "%.2f", min(duration, from + 10)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 310, height: 270), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "录制片段"; window.isReleasedWhenClosed = false; window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary]
        start.identifier = NSUserInterfaceItemIdentifier("clip-start")
        end.identifier = NSUserInterfaceItemIdentifier("clip-end")
        let subtitle = NSButton(checkboxWithTitle: "烧录字幕（暂不支持）", target: nil, action: nil)
        subtitle.isEnabled = false
        let fields = NSGridView(views: [[NSTextField(labelWithString: "开始（秒）"), start], [NSTextField(labelWithString: "结束（秒）"), end]])
        fields.rowSpacing = 8; fields.columnSpacing = 8
        let buttons = NSStackView(views: [NSButton(title: "取消", target: self, action: #selector(cancel)), NSButton(title: "开始", target: self, action: #selector(begin))])
        buttons.spacing = 12
        let stack = NSStackView(views: [fields, subtitle, status, buttons])
        stack.orientation = .vertical; stack.spacing = 10; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16), stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16)])
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func cancel() { close() }
    @objc private func begin() {
        guard let from = Double(start.stringValue), let to = Double(end.stringValue), let range = NativeClipRange(start: from, end: to, duration: duration) else {
            status.stringValue = "请输入有效起止秒数（至少 0.2 秒，且不超出视频时长）"; return
        }
        onStart?(range)
        close()
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true; onClose?(); onClose = nil; onStart = nil
    }
}

/// Publishes app-created output without replacing or reading previous captures.
final class NativeToolOutputStore {
    let homeDirectory: URL
    private let identifier: () -> String
    private let timestamp = Int(Date().timeIntervalSince1970)

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, identifier: @escaping () -> String = { UUID().uuidString }) {
        self.homeDirectory = homeDirectory; self.identifier = identifier
    }
    func directory(for kind: NativeToolDraftKind) -> URL {
        let path: String
        switch kind {
        case .screenshot: path = "Pictures/AIPlayer/Screenshots"
        case .gif: path = "Pictures/AIPlayer/GIF"
        case .poster: path = "Pictures/AIPlayer/Posters"
        case .recording: path = "Movies/AIPlayer/Clips"
        }
        return homeDirectory.appendingPathComponent(path, isDirectory: true)
    }
    func save(_ draft: NativeToolDraft) throws -> URL {
        let files = FileManager.default, folder = directory(for: draft.kind)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".aiplayer-capture-" + UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        try draft.save(to: staging)
        for _ in 0..<16 {
            let output = folder.appendingPathComponent("AIPlayer-\(draft.kind.rawValue)-\(timestamp)-\(identifier()).\(draft.kind.fileExtension)")
            do {
                // Staging and output are on the same filesystem. Creating a
                // hard link publishes the complete file atomically and fails
                // if a concurrent capture already owns this name.
                try files.linkItem(at: staging, to: output)
                return output
            } catch {
                let ns = error as NSError
                guard (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteFileExistsError) || (ns.domain == NSPOSIXErrorDomain && ns.code == 17) else { throw error }
            }
        }
        throw MediaToolError.message("无法分配唯一的自动保存文件名")
    }
}

/// Owns disposable working files, never the published automatic-save output.
final class NativeToolDraft {
    let kind: NativeToolDraftKind
    let directory: URL
    let fileURL: URL
    private(set) var savedURL: URL?
    init(kind: NativeToolDraftKind) throws {
        self.kind = kind
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-draft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("capture." + kind.fileExtension)
    }
    @discardableResult func autoSave(using store: NativeToolOutputStore) throws -> URL {
        if let savedURL { return savedURL }
        let output = try store.save(self)
        savedURL = output
        return output
    }
    func save(to output: URL) throws {
        let files = FileManager.default
        let destination = output.standardizedFileURL
        guard destination.isFileURL, !destination.path.hasPrefix(directory.standardizedFileURL.path + "/"),
              let attributes = try? files.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw MediaToolError.message("预览内容不存在或保存位置无效")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".aiplayer-export-" + UUID().uuidString)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: fileURL, to: staging)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else { try files.moveItem(at: staging, to: destination) }
    }
    func close() { try? FileManager.default.removeItem(at: directory) }
    deinit { close() }
}

final class NativeToolPreviewController: NSWindowController, NSWindowDelegate {
    let draft: NativeToolDraft
    var onClose: (() -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "")
    private var closed = false
    private var videoPlayer: AVPlayer?

    init(draft: NativeToolDraft) {
        self.draft = draft
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 280),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = [NativeToolDraftKind.screenshot: "截图预览", .gif: "GIF 预览", .poster: "海报预览", .recording: "录制完成"][draft.kind]!
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 240)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        let content = window.contentView!
        let image: NSView
        if draft.kind == .recording {
            let video = AVPlayerView()
            videoPlayer = AVPlayer(url: draft.fileURL); videoPlayer?.isMuted = true
            video.player = videoPlayer; video.controlsStyle = .inline
            image = video
        } else {
            let preview = NSImageView()
            preview.identifier = NSUserInterfaceItemIdentifier("native-tool-preview-image")
            preview.image = NSImage(contentsOf: draft.fileURL)
            preview.imageScaling = .scaleProportionallyUpOrDown; preview.animates = true
            image = preview
        }
        // A decoded frame's pixel dimensions must never become the floating
        // window's minimum size. The surrounding constraints own its viewport.
        for orientation: NSLayoutConstraint.Orientation in [.horizontal, .vertical] {
            image.setContentCompressionResistancePriority(.init(1), for: orientation)
            image.setContentHuggingPriority(.init(1), for: orientation)
        }
        image.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(image)
        status.stringValue = draft.savedURL == nil ? "预览已生成。" : "已自动保存到 \(draft.kind == .recording ? "影片" : "图片") / AIPlayer。"
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let close = NSButton(title: "关闭", target: self, action: #selector(discard))
        var controls: [NSView] = [NSButton(title: "打开文件", target: self, action: #selector(openFile)), NSButton(title: "打开文件夹", target: self, action: #selector(openFolder))]
        if draft.kind != .recording { controls.append(NSButton(title: "复制", target: self, action: #selector(copyImage))) }
        controls.append(close)
        let bar = NSStackView(views: controls)
        bar.spacing = 6; bar.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status); content.addSubview(bar)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            image.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            image.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            image.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func discard() { close() }
    @objc private func copyImage() {
        guard let data = try? Data(contentsOf: draft.fileURL) else { status.stringValue = "无法复制预览"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(draft.kind == .gif ? UTType.gif.identifier : UTType.png.identifier))
        status.stringValue = "已复制到剪贴板"
    }
    @objc private func openFile() { if let url = draft.savedURL { NSWorkspace.shared.open(url) } }
    @objc private func openFolder() { if let url = draft.savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true; videoPlayer?.pause(); videoPlayer?.replaceCurrentItem(with: nil); videoPlayer = nil
        draft.close(); onClose?(); onClose = nil
    }
}

final class NativeCaptureProgressController: NSWindowController, NSWindowDelegate {
    var onCancel: (() -> Void)?
    private let status: NSTextField
    private let image = NSImageView()
    private var closed = false

    init(title: String, preview: NSImage? = nil) {
        status = NSTextField(wrappingLabelWithString: title)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]; window.delegate = self
        image.image = preview; image.imageScaling = .scaleProportionallyUpOrDown
        for orientation: NSLayoutConstraint.Orientation in [.horizontal, .vertical] {
            image.setContentCompressionResistancePriority(.init(1), for: orientation)
            image.setContentHuggingPriority(.init(1), for: orientation)
        }
        image.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [image, status, NSButton(title: "取消", target: self, action: #selector(cancel))])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            image.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func cancel() { close() }
    func update(_ message: String) { status.stringValue = message }
    func updatePreview(_ preview: NSImage?) { image.image = preview }
    func finish() { onCancel = nil; close() }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true; onCancel?(); onCancel = nil
    }
}

struct PosterMetadata {
    let title: String
    let duration: Double
    let width: Int
    let height: Int

    var timestamps: [Double] { (1...6).map { duration * Double($0) / 7 } }
}

/// Sequential, bounded snapshots. The player adapter owns seeking and restoring
/// playback; this coordinator never receives a source file path or URL.
final class NativePosterCapture {
    typealias Snapshot = (Double, URL, @escaping (Result<Void, Error>) -> Void) -> Void
    private let metadata: PosterMetadata
    private let snapshot: Snapshot
    private let restore: () -> Void
    private let frameTimeout: TimeInterval
    private var completion: ((Result<Int, Error>) -> Void)?
    private var directory: URL?
    private var timeout: Timer?
    private var frames: [CGImage] = []
    private var started = false

    init(metadata: PosterMetadata, frameTimeout: TimeInterval = 4, snapshot: @escaping Snapshot, restore: @escaping () -> Void) {
        self.metadata = metadata; self.snapshot = snapshot; self.restore = restore
        self.frameTimeout = frameTimeout
    }

    func start(to output: URL, completion: @escaping (Result<Int, Error>) -> Void) throws {
        guard !started, metadata.duration.isFinite, (0.5...604_800).contains(metadata.duration),
              (1...32_768).contains(metadata.width), (1...32_768).contains(metadata.height),
              frameTimeout.isFinite, frameTimeout > 0, frameTimeout <= 4 else {
            throw MediaToolError.message("当前媒体无法生成时间线海报")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-poster-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory; self.completion = completion; started = true
        captureNext(to: output)
    }

    func cancel() { finish(.failure(MediaToolError.message("海报生成已取消"))) }

    private func captureNext(to output: URL) {
        guard completion != nil, let directory else { return }
        let index = frames.count
        guard index < metadata.timestamps.count else {
            let captured = frames, metadata = metadata
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let encoded = Result { try Self.encode(frames: captured, metadata: metadata) }
                DispatchQueue.main.async {
                    guard let self, self.completion != nil else { return }
                    do {
                        try encoded.get().write(to: output, options: .atomic)
                        self.finish(.success(captured.count))
                    } catch { self.finish(.failure(MediaToolError.message("海报保存失败"))) }
                }
            }
            return
        }
        let file = directory.appendingPathComponent("frame-\(index).png")
        let timer = Timer(timeInterval: frameTimeout, repeats: false) { [weak self] _ in
            self?.finish(.failure(MediaToolError.message("媒体画面加载超时，海报未保存")))
        }
        timeout = timer
        RunLoop.main.add(timer, forMode: .common)
        snapshot(metadata.timestamps[index], file) { [weak self] result in
            guard let self, self.completion != nil, self.frames.count == index else { return }
            self.timeout?.invalidate(); self.timeout = nil
            do {
                try result.get()
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw MediaToolError.message("当前媒体没有可用的视频画面")
                }
                self.frames.append(try NativeMediaTools.resized(image, maximumWidth: 640))
                self.captureNext(to: output)
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<Int, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.invalidate(); timeout = nil
        restore()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; frames.removeAll()
        completion(result)
    }

    private static func encode(frames: [CGImage], metadata: PosterMetadata) throws -> Data {
        let width = 1200, height = 620
        guard frames.count == 6,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw MediaToolError.message("无法准备海报画布")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let title = String(metadata.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(140))
        (title.isEmpty ? "AIPlayer" : title as NSString).draw(in: NSRect(x: 24, y: 566, width: 1152, height: 32), withAttributes: [
            .font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white])
        let info = "\(timestamp(metadata.duration))  ·  \(metadata.width) × \(metadata.height)  ·  AIPlayer 时间线海报"
        (info as NSString).draw(at: NSPoint(x: 24, y: 540), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)])
        for (index, image) in frames.enumerated() {
            let tile = NSRect(x: 24 + (index % 3) * 388, y: 290 - (index / 3) * 258, width: 376, height: 216)
            NSColor.black.setFill(); tile.fill()
            let scale = min(tile.width / Double(image.width), tile.height / Double(image.height))
            let size = NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            graphics.cgContext.draw(image, in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
            (timestamp(metadata.timestamps[index]) as NSString).draw(at: NSPoint(x: tile.minX, y: tile.minY - 23), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(calibratedRed: 1, green: 0.78, blue: 0.23, alpha: 1)])
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw MediaToolError.message("海报编码失败") }
        return data
    }

    private static func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
}

final class GIFFrameWriter {
    private let destination: CGImageDestination
    private let expected: Int
    private let fps: Int
    private let maximumWidth: Int
    private var written = 0
    private var finished = false

    init(url: URL, frameCount: Int, fps: Int, maximumWidth: Int = 640) throws {
        guard (1...4500).contains(frameCount), (1...30).contains(fps), [640, 1280, 1920, 3840].contains(maximumWidth),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw MediaToolError.message("无法创建 GIF 文件")
        }
        self.destination = destination; expected = frameCount; self.fps = fps; self.maximumWidth = maximumWidth
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    }

    func append(_ image: CGImage, delay: Double? = nil) throws {
        guard !finished, written < expected else { throw MediaToolError.message("GIF 已结束或帧数超限") }
        let frame = image.width <= maximumWidth ? image : try NativeMediaTools.resized(image, maximumWidth: maximumWidth)
        let delay = delay ?? 1.0 / Double(fps)
        guard delay.isFinite, delay >= 0.02, delay <= 300 else { throw MediaToolError.message("GIF 帧时长无效") }
        CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay
        ]] as CFDictionary)
        written += 1
    }

    func finish() throws {
        guard !finished, written == expected else { throw MediaToolError.message("GIF 尚未收齐画面") }
        finished = true
        guard CGImageDestinationFinalize(destination) else { throw MediaToolError.message("GIF 保存失败") }
    }
}

private final class GIFEncodingCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Works only on a snapshot supplied by our own player. No screen capture, media upload or model API.
final class NativeMediaTools {
    private let snapshot: (URL) throws -> Void
    typealias GIFSnapshot = (Int, @escaping (Result<CGImage, Error>) -> Void) -> Void
    private let gifSnapshot: GIFSnapshot?
    private struct CachedFrame {
        let width: Int, height: Int, bytesPerRow: Int
        let bitmapInfo: UInt32
    }
    private var fastFrames: [CachedFrame] = []
    private var sampleInFlight = false
    private var stopRequested = false
    private var cachedBytes = 0
    private var captureTimer: Timer?
    private var captureCompletion: ((Result<Int, Error>) -> Void)?
    private var temporaryDirectory: URL?
    private var captureOutput: URL?
    private var captureFPS = 10
    private var captureMaximumWidth = 640
    private var captureStartedAt: Date?
    private var captureFrameTimes: [Double] = []
    private var finishedCaptureDuration = 0.0
    private var captureLimit: Int?
    private var captureGeneration = 0
    private var encodingCancellation: GIFEncodingCancellation?
    private(set) var capturedFrameCount = 0
    var captureDuration: Double {
        if captureLimit != nil { return Double(capturedFrameCount) / Double(captureFPS) }
        if isCapturing, let captureStartedAt { return Date().timeIntervalSince(captureStartedAt) }
        return finishedCaptureDuration
    }

    init(snapshot: @escaping (URL) throws -> Void, gifSnapshot: GIFSnapshot? = nil) { self.snapshot = snapshot; self.gifSnapshot = gifSnapshot }
    deinit { captureTimer?.invalidate(); encodingCancellation?.cancel(); removeTemporaryDirectory() }
    var isCapturing: Bool { captureTimer != nil }
    var isProcessingGIF: Bool { captureCompletion != nil }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func resized(_ image: CGImage, maximumWidth: Int) throws -> CGImage {
        guard maximumWidth > 0, image.width > 0, image.height > 0 else { throw MediaToolError.message("画面尺寸无效") }
        let scale = min(1, Double(maximumWidth) / Double(image.width))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaToolError.message("无法准备画面")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw MediaToolError.message("无法缩放画面") }
        return result
    }

    func recognizeCurrentFrame() throws -> String {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ocr.png")
        try snapshot(file)
        return try Self.recognize(loadImage(file))
    }

    func captureGIF(to output: URL, settings: GIFCaptureSettings, completion: @escaping (Result<Int, Error>) -> Void) throws {
        try beginGIF(to: output, fps: settings.fps, maximumWidth: 640, limit: settings.frameCount, completion: completion)
    }

    /// Manual duration: the caller stops recording with finishCapture(). No windows are presented.
    /// Local safety bounds are 300 seconds / 4500 frames, not a claim about OmniPlayer's limits.
    func startGIF(to output: URL, fps: Int = 10, maximumWidth: Int = 640, completion: @escaping (Result<Int, Error>) -> Void) throws {
        try beginGIF(to: output, fps: fps, maximumWidth: maximumWidth, limit: nil, completion: completion)
    }

    private func beginGIF(to output: URL, fps: Int, maximumWidth: Int, limit: Int?, completion: @escaping (Result<Int, Error>) -> Void) throws {
        guard captureCompletion == nil else { throw MediaToolError.message("已有 GIF 正在生成") }
        guard (1...30).contains(fps), [640, 1280, 1920, 3840].contains(maximumWidth) else { throw MediaToolError.message("GIF 帧率或分辨率无效") }
        let directory = try makeTemporaryDirectory()
        temporaryDirectory = directory
        captureGeneration += 1
        captureOutput = output; captureFPS = fps; captureMaximumWidth = maximumWidth; captureStartedAt = Date(); captureLimit = limit
        captureFrameTimes = []; finishedCaptureDuration = 0
        fastFrames = []; sampleInFlight = false; stopRequested = false; cachedBytes = 0
        capturedFrameCount = 0
        captureCompletion = completion
        let timer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            guard let self else { return }
            if let gifSnapshot = self.gifSnapshot {
                self.sampleGIFFrame(using: gifSnapshot, directory: directory)
                return
            }
            do {
                let frameTime = Date().timeIntervalSince(self.captureStartedAt!)
                try autoreleasepool {
                    let frameFile = directory.appendingPathComponent("frame-\(self.capturedFrameCount).png")
                    try self.snapshot(frameFile)
                    // Preserve original PNGs at/below the selected width, including 4K. Never upscale.
                    let image = try self.loadImage(frameFile)
                    if image.width > maximumWidth {
                        let resized = try Self.resized(image, maximumWidth: maximumWidth)
                        guard let destination = CGImageDestinationCreateWithURL(frameFile as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                            throw MediaToolError.message("GIF 帧缓存失败")
                        }
                        CGImageDestinationAddImage(destination, resized, nil)
                        guard CGImageDestinationFinalize(destination) else { throw MediaToolError.message("GIF 帧缓存失败") }
                    }
                }
                self.captureFrameTimes.append(frameTime)
                self.capturedFrameCount += 1
                if self.capturedFrameCount >= (self.captureLimit ?? 4500) || Date().timeIntervalSince(self.captureStartedAt!) >= 300 {
                    self.finishCapture()
                }
            } catch { self.complete(.failure(error)) }
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
    }

    func finishCapture() {
        guard isCapturing else { return }
        finishedCaptureDuration = captureDuration
        captureTimer?.invalidate(); captureTimer = nil
        stopRequested = true
        // A single background sample may already be in progress. Commit it before
        // encoding; no truncated frame, cache race, or synchronous main-thread wait.
        if !sampleInFlight { encodeGIF() }
    }

    private func sampleGIFFrame(using sample: GIFSnapshot, directory: URL) {
        guard !sampleInFlight, !stopRequested, let started = captureStartedAt else { return }
        sampleInFlight = true
        let generation = captureGeneration, index = capturedFrameCount
        let timestamp = Date().timeIntervalSince(started)
        sample(captureMaximumWidth) { [weak self] imageResult in
            // Providers may complete on any queue; lossless caching never runs
            // on AppKit's event loop. Only one frame is live/in-flight at a time.
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<(CachedFrame, Int), Error> = Result {
                    let image = try imageResult.get()
                    guard let pixels = image.dataProvider?.data else { throw MediaToolError.message("GIF 画面缓存无效") }
                    let raw = pixels as Data
                    // LZFSE took ~0.5 seconds per UHD frame. LZ4 is still
                    // lossless but fits the real-time sampling budget.
                    let packed = try (raw as NSData).compressed(using: .lz4) as Data
                    try packed.write(to: directory.appendingPathComponent("frame-\(index).raw"), options: .atomic)
                    return (CachedFrame(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow, bitmapInfo: image.bitmapInfo.rawValue), packed.count)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.captureGeneration, self.captureCompletion != nil else { return }
                    self.sampleInFlight = false
                    switch result {
                    case .failure(let error): self.complete(.failure(error))
                    case .success(let (frame, bytes)):
                        self.fastFrames.append(frame); self.captureFrameTimes.append(timestamp)
                        self.capturedFrameCount += 1; self.cachedBytes += bytes
                        if self.stopRequested { self.encodeGIF() }
                        else if self.capturedFrameCount >= (self.captureLimit ?? 4500) || Date().timeIntervalSince(started) >= 300 || self.cachedBytes >= 4 * 1024 * 1024 * 1024 { self.finishCapture() }
                        else if Date().timeIntervalSince(started) - timestamp >= 1 / Double(self.captureFPS), let next = self.gifSnapshot {
                            // A slow frame must not also wait for the next timer
                            // tick: that used to halve cadence around a deadline.
                            self.sampleGIFFrame(using: next, directory: directory)
                        }
                    }
                }
            }
        }
    }

    private func encodeGIF() {
        guard let directory = temporaryDirectory, let output = captureOutput else { return }
        temporaryDirectory = nil // The encoding worker owns and cleans its cache from this point.
        let count = capturedFrameCount, fps = captureFPS, maximumWidth = captureMaximumWidth, generation = captureGeneration
        let frameTimes = captureFrameTimes, actualDuration = finishedCaptureDuration, fixedTiming = captureLimit != nil
        let cachedFrames = fastFrames
        let partial = directory.appendingPathComponent("capture.gif")
        let cancellation = GIFEncodingCancellation()
        encodingCancellation = cancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Int, Error>
            do {
                let writer = try GIFFrameWriter(url: partial, frameCount: count, fps: fps, maximumWidth: maximumWidth)
                for index in 0..<count {
                    guard !cancellation.isCancelled else { throw MediaToolError.message("GIF 生成已取消") }
                    try autoreleasepool {
                        let image: CGImage
                        if index < cachedFrames.count {
                            let frame = cachedFrames[index]
                            let packed = try Data(contentsOf: directory.appendingPathComponent("frame-\(index).raw"))
                            let raw = try (packed as NSData).decompressed(using: .lz4) as Data
                            guard raw.count >= frame.bytesPerRow * frame.height,
                                  let provider = CGDataProvider(data: raw as CFData),
                                  let decoded = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: frame.bitmapInfo),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw MediaToolError.message("GIF 帧缓存无法读取") }
                            image = decoded
                        } else {
                            let frame = directory.appendingPathComponent("frame-\(index).png")
                            guard let source = CGImageSourceCreateWithURL(frame as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw MediaToolError.message("GIF 帧缓存无法读取") }
                            image = decoded
                        }
                        let nextTime = index + 1 < count ? frameTimes[index + 1] : actualDuration
                        let delay = fixedTiming ? nil : max(0.02, nextTime - frameTimes[index])
                        try writer.append(image, delay: delay)
                    }
                }
                try writer.finish()
                guard !cancellation.isCancelled else { throw MediaToolError.message("GIF 生成已取消") }
                result = .success(count)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                defer { try? FileManager.default.removeItem(at: directory) }
                guard let self, self.captureGeneration == generation else { return }
                self.encodingCancellation = nil
                do {
                    let frames = try result.get()
                    // Publication and cancellation both run on main: no cancelled export can leak a file.
                    // A hard link fails atomically when output exists; no user file is overwritten.
                    try FileManager.default.linkItem(at: partial, to: output)
                    self.complete(.success(frames))
                } catch { self.complete(.failure(error)) }
            }
        }
    }

    func cancelCapture() {
        guard captureCompletion != nil else { return }
        captureGeneration += 1
        encodingCancellation?.cancel(); encodingCancellation = nil
        complete(.failure(MediaToolError.message("GIF 生成已取消")))
    }

    private func complete(_ result: Result<Int, Error>) {
        captureTimer?.invalidate(); captureTimer = nil
        let completion = captureCompletion; captureCompletion = nil
        removeTemporaryDirectory()
        completion?(result)
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MediaToolError.message("当前媒体没有可识别的画面")
        }
        return image
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func removeTemporaryDirectory() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }
}
