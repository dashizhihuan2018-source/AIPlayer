import AppKit
import Foundation
import OpenGL.GL3
import UniformTypeIdentifiers
import WebKit

final class MPVEngine {
    private(set) var handle: OpaquePointer?
    private(set) var rendererReady = false
    private(set) var lastError: String?
    private(set) var ended = false
    private(set) var playbackRestartGeneration: UInt64 = 0
    private var activeEntryID: Int64?
    private var suppressEOFUntilRestart = false
    var awaitingDecodedFrame: Bool { suppressEOFUntilRestart }

    init() throws {
        guard let created = aiplayer_mpv_create() else {
            throw NSError(domain: "AIPlayer.mpv", code: -1, userInfo: [NSLocalizedDescriptionKey: "libmpv initialization failed"])
        }
        handle = created
    }

    deinit {
        if let handle { aiplayer_mpv_destroy(handle) }
    }

    func initializeRenderer(update: @escaping AIPlayerMPVUpdateCallback, context: UnsafeMutableRawPointer) throws {
        guard let handle else { throw engineError(-1) }
        aiplayer_mpv_set_update_callback(handle, update, context)
        let status = aiplayer_mpv_initialize_renderer(handle)
        try check(status)
        rendererReady = true
    }

    func render(framebuffer: Int32, width: Int32, height: Int32) {
        guard let handle, rendererReady else { return }
        let status = aiplayer_mpv_render(handle, framebuffer, width, height)
        if status < 0 {
            let message = engineError(status).localizedDescription
            DispatchQueue.main.async { [weak self] in self?.lastError = message }
        }
    }

    func reportSwap() {
        guard let handle, rendererReady else { return }
        aiplayer_mpv_report_swap(handle)
    }

    func shutdownRenderer() {
        guard let handle, rendererReady else { return }
        aiplayer_mpv_shutdown_renderer(handle)
        rendererReady = false
    }

    @discardableResult
    func load(_ location: String, position: Double?) throws -> Int64 {
        if let position, position > 0 { try command(["loadfile", location, "replace", "-1", "start=\(position)"]) }
        else { try command(["loadfile", location, "replace"]) }
        ended = false
        suppressEOFUntilRestart = true
        let playlistPosition = integer("playlist-pos", fallback: -1)
        let entryID = playlistPosition >= 0 ? integer("playlist/\(playlistPosition)/id", fallback: -1) : -1
        guard entryID >= 0 else {
            throw NSError(domain: "AIPlayer.mpv", code: -4, userInfo: [NSLocalizedDescriptionKey: "libmpv did not expose the accepted playlist entry"])
        }
        return entryID
    }

    func addSubtitle(_ path: String) throws { try command(["sub-add", path, "select"]) }
    func screenshot(to path: String) throws { try command(["screenshot-to-file", path, "subtitles"]) }
    func setFrameCaptureDecoder(_ mode: String) throws { try setString("hwdec", mode) }
    func captureFrameAsync(to path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let handle else { completion(.failure(engineError(-1))); return }
        // mpv's client command API is thread-safe. PNG conversion and disk I/O
        // must not stall the app's event loop, especially for large UHD frames.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let status = aiplayer_mpv_command2(handle, "screenshot-to-file", path, "subtitles")
            let result: Result<Void, Error> = status < 0 ? .failure(engineError(status)) : .success(())
            DispatchQueue.main.async { completion(result) }
        }
    }
    /// Keep PNG encoding off the render/event loop and avoid it altogether for GIF sampling.
    func captureGIFFrame(maximumWidth: Int, completion: @escaping (Result<CGImage, Error>) -> Void) {
        guard let handle else { completion(.failure(engineError(-1))); return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result: Result<CGImage, Error> = Result {
                var pixels: UnsafeMutablePointer<UInt8>?
                var width: Int32 = 0, height: Int32 = 0, stride: Int32 = 0
                let status = aiplayer_mpv_capture_rgba(handle, &pixels, &width, &height, &stride)
                if status < 0 { throw engineError(status) }
                guard let pixels else { throw MediaToolError.message("GIF 无法读取播放画面") }
                defer { aiplayer_mpv_free_frame(pixels) }
                let data = Data(bytes: pixels, count: Int(stride) * Int(height))
                guard let provider = CGDataProvider(data: data as CFData),
                      let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: Int(stride), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw MediaToolError.message("GIF 画面数据无效") }
                return image.width > maximumWidth ? try NativeMediaTools.resized(image, maximumWidth: maximumWidth) : image
            }
            completion(result)
        }
    }
    func setStreamRecording(to path: String?) throws { try setString("stream-record", path ?? "") }

    func execute(_ command: ValidatedEngineCommand) throws {
        // A restart queued before this seek cannot acknowledge the new frame.
        if case .seek = command { _ = drainEvents() }
        for instruction in MPVCommandCompiler.compile(command) {
            switch instruction {
            case .setString(let name, let value): try setString(name, value)
            case .setDouble(let name, let value): try setDouble(name, value)
            case .setFlag(let name, let value): try setFlag(name, value)
            case .command(let args): try self.command(args)
            }
        }
        if case .seek = command {
            ended = false
            lastError = nil
            suppressEOFUntilRestart = true
        }
    }

    func string(_ name: String, fallback: String = "") -> String {
        guard let handle, let pointer = aiplayer_mpv_get_string(handle, name) else { return fallback }
        defer { aiplayer_mpv_free_string(pointer) }
        return String(cString: pointer)
    }

    func double(_ name: String, fallback: Double = 0) -> Double {
        guard let handle else { return fallback }
        let value = aiplayer_mpv_get_double(handle, name, fallback)
        return value.isFinite ? value : fallback
    }

    func integer(_ name: String, fallback: Int64 = 0) -> Int64 {
        guard let handle else { return fallback }
        return aiplayer_mpv_get_int64(handle, name, fallback)
    }

    func flag(_ name: String, fallback: Bool = false) -> Bool {
        guard let handle else { return fallback }
        return aiplayer_mpv_get_flag(handle, name, fallback ? 1 : 0) != 0
    }

    @discardableResult
    func drainEvents() -> [NativeLoadLifecycleEvent] {
        guard let handle else { return [] }
        var result: [NativeLoadLifecycleEvent] = []
        var raw = AIPlayerMPVLifecycleEvent()
        while aiplayer_mpv_next_event(handle, &raw) != 0 {
            let event: NativeLoadLifecycleEvent
            switch raw.type {
            case Int32(AIPLAYER_MPV_EVENT_START_FILE):
                event = .startFile(entryID: raw.playlist_entry_id)
                activeEntryID = raw.playlist_entry_id
                ended = false; lastError = nil
            case Int32(AIPLAYER_MPV_EVENT_FILE_LOADED):
                event = .fileLoaded(entryID: raw.playlist_entry_id)
                suppressEOFUntilRestart = false
                ended = false; lastError = nil
            case Int32(AIPLAYER_MPV_EVENT_END_FILE):
                event = .ended(entryID: raw.playlist_entry_id, error: raw.error)
                if activeEntryID == raw.playlist_entry_id {
                    if !suppressEOFUntilRestart, raw.reason == AIPLAYER_MPV_END_REASON_EOF { ended = true }
                    if raw.error < 0 { lastError = engineError(raw.error).localizedDescription }
                }
            case Int32(AIPLAYER_MPV_EVENT_SEEK):
                event = .seek
                suppressEOFUntilRestart = true
                ended = false; lastError = nil
            case Int32(AIPLAYER_MPV_EVENT_PLAYBACK_RESTART):
                playbackRestartGeneration &+= 1
                event = .playbackRestart
                suppressEOFUntilRestart = false
                ended = false; lastError = nil
            default:
                continue
            }
            result.append(event)
        }
        if !suppressEOFUntilRestart, flag("eof-reached") { ended = true }
        return result
    }

    private func setString(_ name: String, _ value: String) throws {
        guard let handle else { throw engineError(-1) }
        try check(aiplayer_mpv_set_string(handle, name, value))
    }

    private func setDouble(_ name: String, _ value: Double) throws {
        guard let handle else { throw engineError(-1) }
        try check(aiplayer_mpv_set_double(handle, name, value))
    }

    private func setFlag(_ name: String, _ value: Bool) throws {
        guard let handle else { throw engineError(-1) }
        try check(aiplayer_mpv_set_flag(handle, name, value ? 1 : 0))
    }

    private func command(_ args: [String]) throws {
        guard let handle, !args.isEmpty else { throw engineError(-1) }
        let pointer = handle
        let status: Int32
        switch args.count {
        case 1: status = aiplayer_mpv_command0(pointer, args[0])
        case 2: status = aiplayer_mpv_command1(pointer, args[0], args[1])
        case 3: status = aiplayer_mpv_command2(pointer, args[0], args[1], args[2])
        case 4: status = aiplayer_mpv_command3(pointer, args[0], args[1], args[2], args[3])
        case 5: status = aiplayer_mpv_command4(pointer, args[0], args[1], args[2], args[3], args[4])
        default: throw NSError(domain: "AIPlayer.mpv", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported internal mpv command arity"])
        }
        try check(status)
    }

    private func check(_ status: Int32) throws {
        guard status >= 0 else {
            let error = engineError(status)
            lastError = error.localizedDescription
            throw error
        }
        lastError = nil
    }

    private func engineError(_ status: Int32) -> NSError {
        let message = aiplayer_mpv_error(status).map { String(cString: $0) } ?? "unknown libmpv error"
        return NSError(domain: "AIPlayer.mpv", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class MPVVideoView: NSOpenGLView {
    let engine: MPVEngine
    // libmpv explicitly forbids a render thread waiting for its synchronous
    // client API. AppKit owns controls/property reads, this queue owns GL only.
    private let renderQueue = DispatchQueue(label: "AIPlayer.video-render", qos: .userInteractive)
    private var renderContext: NSOpenGLContext?
    private var renderSize = NSSize(width: 1, height: 1) // renderQueue only
    private var gifTexture: GLuint = 0
    private var gifFramebuffer: GLuint = 0
    private var gifSourceSize = NSSize.zero
    private var gifLastSample = Date.distantPast
    private var gifFrameAvailable = false

    init?(frame frameRect: NSRect, engine: MPVEngine) {
        self.engine = engine
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile), NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize), 8,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer), NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            0
        ]
        super.init(frame: frameRect, pixelFormat: NSOpenGLPixelFormat(attributes: attributes)!)
        renderContext = openGLContext
        wantsBestResolutionOpenGLSurface = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { shutdownRenderer() }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        NSOpenGLContext.clearCurrentContext()
        do { try initializeRenderer() }
        catch { NSLog("libmpv renderer initialization failed: %@", error.localizedDescription) }
    }

    func initializeRenderer() throws {
        guard !engine.rendererReady else { return }
        NSOpenGLContext.clearCurrentContext()
        try renderQueue.sync {
            guard let context = renderContext else { throw MediaToolError.message("视频渲染上下文不可用") }
            context.makeCurrentContext()
            var swapInterval: GLint = 1
            context.setValues(&swapInterval, for: .swapInterval)
            try engine.initializeRenderer(update: { context in
                guard let context else { return }
                let view = Unmanaged<MPVVideoView>.fromOpaque(context).takeUnretainedValue()
                // Never wait for AppKit to service a core render request.
                view.requestRender()
            }, context: Unmanaged.passUnretained(self).toOpaque())
            NSOpenGLContext.clearCurrentContext()
        }
    }

    func shutdownRenderer() {
        guard engine.rendererReady else { return }
        renderQueue.sync {
            renderContext?.makeCurrentContext()
            releaseGIFSurface()
            engine.shutdownRenderer()
            NSOpenGLContext.clearCurrentContext()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pixels = convertToBacking(bounds).size
        renderQueue.async { [weak self] in
            self?.renderSize = pixels
            self?.renderFrame()
        }
    }

    private func requestRender() {
        renderQueue.async { [weak self] in self?.renderFrame() }
    }

    private func renderFrame() {
        guard engine.rendererReady, let context = renderContext, let cgl = context.cglContextObj else { return }
        CGLLockContext(cgl)
        defer { NSOpenGLContext.clearCurrentContext(); CGLUnlockContext(cgl) }
        context.makeCurrentContext()
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        let width = Int32(max(1, renderSize.width)), height = Int32(max(1, renderSize.height))
        if gifFramebuffer != 0 && Date().timeIntervalSince(gifLastSample) < 0.5 {
            // Render ONCE at the source dimensions, then blit to the window.
            // A second mpv render call for a snapshot would pull/wait for a
            // future frame, lowering cadence and disturbing display timing.
            engine.render(framebuffer: Int32(gifFramebuffer), width: Int32(gifSourceSize.width), height: Int32(gifSourceSize.height))
            gifFrameAvailable = true
            glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(framebuffer))
            glClearColor(0, 0, 0, 1); glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            let scale = min(Double(width) / gifSourceSize.width, Double(height) / gifSourceSize.height)
            let targetWidth = Int32(gifSourceSize.width * scale), targetHeight = Int32(gifSourceSize.height * scale)
            let x = (width - targetWidth) / 2, y = (height - targetHeight) / 2
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), gifFramebuffer)
            glBlitFramebuffer(0, 0, GLint(gifSourceSize.width), GLint(gifSourceSize.height), x, y, x + targetWidth, y + targetHeight, GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(framebuffer))
        } else {
            releaseGIFSurface()
            engine.render(framebuffer: framebuffer, width: width, height: height)
        }
        context.flushBuffer()
        engine.reportSwap()
    }

    private func releaseGIFSurface() {
        if gifFramebuffer != 0 { glDeleteFramebuffers(1, &gifFramebuffer); gifFramebuffer = 0 }
        if gifTexture != 0 { glDeleteTextures(1, &gifTexture); gifTexture = 0 }
        gifSourceSize = .zero; gifFrameAvailable = false
    }

    private func prepareGIFSurface(width: Int, height: Int) throws {
        if gifSourceSize == NSSize(width: width, height: height), gifFramebuffer != 0 { return }
        releaseGIFSurface()
        glGenTextures(1, &gifTexture); glGenFramebuffers(1, &gifFramebuffer)
        glBindTexture(GLenum(GL_TEXTURE_2D), gifTexture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), nil)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), gifFramebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), gifTexture, 0)
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            releaseGIFSurface(); throw MediaToolError.message("GIF 无法创建原尺寸画面缓冲")
        }
        gifSourceSize = NSSize(width: width, height: height)
    }

    /// Capture through the existing render API, not screenshot-raw: that client
    /// command waits for the next VO frame while holding mpv's core, starving
    /// property/control reads at high playback speeds. The FBO is source-sized,
    /// not a screenshot/upscale of the smaller window or the desktop.
    func captureGIFFrame(maximumWidth: Int, completion: @escaping (Result<CGImage, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Client properties must never be read from the GL render queue.
            let sourceWidth = Int(engine.integer("video-out-params/dw", fallback: engine.integer("video-params/w")))
            let sourceHeight = Int(engine.integer("video-out-params/dh", fallback: engine.integer("video-params/h")))
            guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 8192, sourceHeight <= 8192,
                  sourceWidth * sourceHeight <= 33_554_432 else {
                completion(.failure(MediaToolError.message("GIF 画面尺寸不可用"))); return
            }
            let scale = min(1, Double(maximumWidth) / Double(sourceWidth))
            let width = max(1, Int(Double(sourceWidth) * scale))
            let height = max(1, Int(Double(sourceHeight) * scale))
            guard width <= 3840, height <= 8192 else {
                completion(.failure(MediaToolError.message("GIF 画面尺寸超出保护范围"))); return
            }
            renderQueue.async { [self] in
                let result: Result<CGImage, Error> = Result {
                    guard engine.rendererReady, let context = renderContext, let cgl = context.cglContextObj else {
                        throw MediaToolError.message("GIF 渲染上下文不可用")
                    }
                    CGLLockContext(cgl)
                    defer { NSOpenGLContext.clearCurrentContext(); CGLUnlockContext(cgl) }
                    context.makeCurrentContext()
                    var previousDraw: GLint = 0, previousRead: GLint = 0
                    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &previousDraw)
                    glGetIntegerv(GLenum(GL_READ_FRAMEBUFFER_BINDING), &previousRead)
                    var texture: GLuint = 0, framebuffer: GLuint = 0
                    defer {
                        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(previousDraw))
                        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(previousRead))
                        glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &texture)
                    }
                    try prepareGIFSurface(width: sourceWidth, height: sourceHeight)
                    gifLastSample = Date()
                    if !gifFrameAvailable {
                        // Initial redraw only; later samples reuse the most
                        // recently displayed source frame without pulling one.
                        engine.render(framebuffer: Int32(gifFramebuffer), width: Int32(sourceWidth), height: Int32(sourceHeight))
                        gifFrameAvailable = true
                    }
                    if width == sourceWidth && height == sourceHeight {
                        // Native-resolution output already exists: don't allocate
                        // and copy a second 32MB UHD GPU surface on every tick.
                        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), gifFramebuffer)
                    } else {
                        glGenTextures(1, &texture); glGenFramebuffers(1, &framebuffer)
                        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
                        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
                        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
                        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), nil)
                        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
                        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
                        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
                            throw MediaToolError.message("GIF 无法创建缩放画面缓冲")
                        }
                        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), gifFramebuffer)
                        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), framebuffer)
                        glBlitFramebuffer(0, 0, GLint(sourceWidth), GLint(sourceHeight), 0, 0, GLint(width), GLint(height), GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_LINEAR))
                        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), framebuffer)
                    }
                    glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 4)
                    var data = Data(count: width * height * 4)
                    data.withUnsafeMutableBytes { pixels in
                        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), pixels.baseAddress)
                        // OpenGL readback begins at the lower row, CGImage at
                        // the upper row. Flip bytes, not playback or the view.
                        let rowSize = width * 4
                        var scratch = [UInt8](repeating: 0, count: rowSize)
                        scratch.withUnsafeMutableBytes { row in
                            for y in 0..<(height / 2) {
                                let top = pixels.baseAddress!.advanced(by: y * rowSize)
                                let bottom = pixels.baseAddress!.advanced(by: (height - 1 - y) * rowSize)
                                memcpy(row.baseAddress!, top, rowSize); memcpy(top, bottom, rowSize); memcpy(bottom, row.baseAddress!, rowSize)
                            }
                        }
                    }
                    guard glGetError() == GLenum(GL_NO_ERROR), let provider = CGDataProvider(data: data as CFData),
                          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                        throw MediaToolError.message("GIF 无法读取渲染画面")
                    }
                    return image
                }
                completion(result)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BookmarkRecord: Codable {
    let id: String
    let name: String
    let bookmark: Data
}

final class MediaAuthorizationStore {
    private let storeURL: URL
    private var records: [String: BookmarkRecord] = [:]

    init(supportDirectory: URL) {
        storeURL = supportDirectory.appendingPathComponent("media-bookmarks.json")
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode([BookmarkRecord].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
    }

    var authorizedIDs: Set<String> { Set(records.keys) }

    func authorize(_ urls: [URL]) throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        for url in urls where NativeMediaFilePolicy.isReadableRegularFile(url) {
            let canonical = url.standardizedFileURL
            let bookmark = try canonical.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.nameKey, .contentTypeKey], relativeTo: nil)
            let id = UUID().uuidString.lowercased()
            let record = BookmarkRecord(id: id, name: canonical.lastPathComponent, bookmark: bookmark)
            records[id] = record
            items.append(["id": id, "name": record.name, "kind": "local"])
        }
        guard !items.isEmpty else { throw MediaToolError.message("请选择可读取的媒体文件。") }
        try persist()
        return items
    }

    func resolve(_ id: String) throws -> URL {
        guard let record = records[id] else { throw NativeBridgeValidationError.unauthorizedLocalID }
        var stale = false
        let url = try URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw NativeBridgeValidationError.unauthorizedLocalID }
        if stale {
            let refreshed = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.nameKey, .contentTypeKey], relativeTo: nil)
            records[id] = BookmarkRecord(id: id, name: record.name, bookmark: refreshed)
            try persist()
        }
        return url
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(records.values.sorted { $0.id < $1.id })
        try data.write(to: storeURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}

final class NativePlayerController {
    private struct PendingLoad {
        let token: NativeLoadToken
        let completion: (Result<Any, Error>) -> Void
        let timeout: DispatchWorkItem
    }

    let engine: MPVEngine
    let videoView: MPVVideoView
    private let store: MediaAuthorizationStore
    private weak var webView: WKWebView?
    private weak var window: NSWindow?
    private var timer: Timer?
    private var activeScopedURL: URL?
    private var activeScopeStarted = false
    private var hasMedia = false
    private let playbackPower = NativePlaybackPower()
    private var keepAwakeEnabled = UserDefaults.standard.object(forKey: "AIPlayer.keepAwake") as? Bool ?? true
    private var requestedVisible = false
    private var recording = false
    private var mediaTools: NativeMediaTools!
    private let openMediaQueue = NativeOpenMediaQueue()
    private var pictureInPictureState: (frame: NSRect, minimumSize: NSSize, level: NSWindow.Level, collectionBehavior: NSWindow.CollectionBehavior)?
    private var windowTransitionGate = NativeWindowTransitionGate()
    private let windowFailureDelegate = NativeWindowFailureDelegate()
    private var windowObservers: [NSObjectProtocol] = []
    private var loadTracker = NativeLoadTracker()
    private var pendingLoad: PendingLoad?
    private var posterCapture: NativePosterCapture?
    private var posterFrameTimer: Timer?
    private var posterPanelOpen = false
    private var previewWindows: [UUID: NativeToolPreviewController] = [:]
    private var progressWindows: [UUID: NativeCaptureProgressController] = [:]
    private var gifSaving = false
    private var gifSavedName: String?
    private var gifError: String?
    private var gifThumbnail: String?
    private var gifStopReplies: [(Result<Any, Error>) -> Void] = []
    private var rangeWindow: NativeRecordingRangeController?
    private var clipExporter: NativeClipExporter?
    private var clipDraft: NativeToolDraft?
    private var toolGeneration = UUID()
    private var currentMediaSource: URL?
    private let watchedFrames = NativeWatchedFrameCache()
    private var nextWatchedSample = Date.distantPast
    var watchedFrameTimes: [Double] { watchedFrames.frames.map(\.time) }
    private let toolPresentation: ((NSWindowController) -> Void)?
    private let toolOutputStore: NativeToolOutputStore
    private let outputFolderOpener: (URL) -> Bool

    init(webView: WKWebView, window: NSWindow, container: NSView, supportDirectory: URL, toolPresentation: ((NSWindowController) -> Void)? = nil, toolOutputStore: NativeToolOutputStore = NativeToolOutputStore(), outputFolderOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) throws {
        self.toolPresentation = toolPresentation
        self.toolOutputStore = toolOutputStore
        self.outputFolderOpener = outputFolderOpener
        engine = try MPVEngine()
        store = MediaAuthorizationStore(supportDirectory: supportDirectory)
        self.webView = webView
        self.window = window
        guard let video = MPVVideoView(frame: .zero, engine: engine) else {
            throw NSError(domain: "AIPlayer.mpv", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to create the OpenGL video surface"])
        }
        videoView = video
        mediaTools = NativeMediaTools(snapshot: { [weak self] destination in
            guard let self, self.hasMedia else { throw MediaToolError.message("当前没有可处理的媒体") }
            try self.engine.screenshot(to: destination.path)
        }, gifSnapshot: { [weak video] width, completion in
            guard let video else { completion(.failure(MediaToolError.message("GIF 播放画面不可用"))); return }
            video.captureGIFFrame(maximumWidth: width, completion: completion)
        })
        videoView.autoresizingMask = []
        videoView.isHidden = true
        // The web document owns the transport and floating tools. A native
        // sibling above WKWebView obscures those controls regardless of CSS
        // z-index or hit testing. Keep video below the transparent web surface;
        // the active native-player document must also clear its CSS backgrounds.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        container.addSubview(videoView, positioned: .below, relativeTo: webView)
        try videoView.initializeRenderer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in self?.emitState() }
        windowFailureDelegate.onFullscreenTransitionFailure = { [weak self] in
            self?.windowTransitionGate.failFullscreenTransition()
            self?.emitWindowState()
        }
        window.delegate = windowFailureDelegate
        observeWindowState(window)
    }

    deinit { shutdown() }

    var authorizedLocalIDs: Set<String> { store.authorizedIDs }

    func shutdown() {
        playbackPower.release()
        watchedFrames.reset()
        timer?.invalidate()
        timer = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if window?.delegate === windowFailureDelegate { window?.delegate = nil }
        pendingLoad?.timeout.cancel()
        pendingLoad = nil
        mediaTools.cancelCapture()
        posterCapture?.cancel()
        closeToolWindows()
        try? stopRecording()
        _ = try? setPictureInPicture(false)
        stopScopedAccess()
        videoView.shutdownRenderer()
    }

    func pickMedia(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .audio, .data]
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true
        panel.title = "打开本地媒体"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            guard response == .OK else { completion(.success([])); return }
            do { completion(.success(try self.store.authorize(panel.urls))) }
            catch { completion(.failure(error)) }
        }
    }

    func openFromSystem(_ urls: [URL]) {
        do {
            openAuthorizedItems(try store.authorize(urls))
        } catch {
            emitState(error: error.localizedDescription)
        }
    }

    func openAuthorizedItems(_ values: [[String: Any]]) {
        let items = values.compactMap { value -> NativeOpenMediaItem? in
            guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
            return .local(id: id, name: name)
        }
        deliverOpenMedia(items)
    }

    func openURLFromSystem(_ url: URL, name: String) {
        deliverOpenMedia([.remote(id: "url-\(UUID().uuidString.lowercased())", name: name, url: url.absoluteString)])
    }

    func pageWillNavigate() {
        openMediaQueue.resetReadiness()
        deactivateVideoSurface()
    }

    private func deactivateVideoSurface() {
        // The native sibling survives WK document replacement, whose JS
        // cleanup messages are not guaranteed to arrive before navigation.
        posterCapture?.cancel()
        closeToolWindows()
        try? stopRecording()
        requestedVisible = false
        videoView.isHidden = true
        try? engine.execute(.pause(true))
    }

    func handle(_ request: ValidatedNativeRequest, completion: @escaping (Result<Any, Error>) -> Void) {
        switch request {
        case .screenshot, .ocr, .captureGIF, .gifStart:
            processEngineEvents()
            if hasMedia && (engine.awaitingDecodedFrame || engine.flag("seeking")) {
                waitForCaptureFrame(request, generation: toolGeneration, deadline: Date().addingTimeInterval(8), completion: completion)
                return
            }
        default: break
        }
        do {
            switch request {
            case .capabilities:
                completion(.success(capabilities()))
            case .keepAwake(let enabled):
                keepAwakeEnabled = enabled
                UserDefaults.standard.set(enabled, forKey: "AIPlayer.keepAwake")
                completion(.success(state()))
            case .openFiles:
                pickMedia { result in completion(result.map { $0 as Any }) }
            case .loadLocal(let id, let position):
                try prepareForMediaTransition()
                try loadLocal(id: id, position: position, completion: completion)
            case .loadURL(let url, let position):
                try prepareForMediaTransition()
                stopScopedAccess()
                currentMediaSource = url
                try beginLoad(location: url.absoluteString, position: position, completion: completion)
            case .engine(let command):
                if posterCapture != nil {
                    if command == .stop { posterCapture?.cancel() }
                    else { throw MediaToolError.message("正在生成海报，请完成或停止后再调整播放") }
                }
                let wasRecording = isRecording
                if case .seek = command, isRecording { try stopRecording() }
                if command == .stop { mediaTools.cancelCapture(); try stopRecording(); cancelPendingLoad(message: "加载已停止") }
                try engine.execute(command)
                if command == .stop { hasMedia = false; videoView.isHidden = true; watchedFrames.reset() }
                let current = state()
                completion(.success(current))
                if wasRecording || command == .stop { emitState(processEvents: false) }
            case .getState:
                completion(.success(state()))
            case .setVideoRect(let rectangle):
                setVideoRectangle(rectangle); completion(.success(["visible": !videoView.isHidden]))
            case .hideVideo:
                requestedVisible = false; videoView.isHidden = true; completion(.success(["visible": false]))
            case .importSubtitle:
                importSubtitle(completion: completion)
            case .screenshot:
                saveScreenshot(completion: completion)
            case .fullscreen:
                toggleFullscreen(completion: completion)
            case .ocr:
                guard posterCapture == nil else { throw MediaToolError.message("正在生成海报，请稍后重试") }
                guard hasMedia else { throw MediaToolError.message("当前没有可识别的媒体") }
                completion(.success(["text": try mediaTools.recognizeCurrentFrame()]))
            case .captureGIF(let duration, let fps):
                captureGIF(duration: duration, fps: fps, completion: completion)
            case .gifStart(let fps, let maximumWidth):
                startManualGIF(fps: fps, maximumWidth: maximumWidth, completion: completion)
            case .gifStop:
                guard mediaTools.isProcessingGIF || gifSaving else { throw MediaToolError.message("当前没有正在录制的 GIF") }
                gifStopReplies.append(completion)
                mediaTools.finishCapture()
                emitState()
            case .gifCancel:
                guard !gifSaving else { throw MediaToolError.message("GIF 正在写入，请等待保存完成") }
                mediaTools.cancelCapture()
                gifThumbnail = nil; gifError = nil
                completion(.success(["cancelled": true, "saved": false])); emitState()
            case .openGifFolder:
                completion(.success(["opened": try openGIFOutputFolder()]))
            case .capturePoster:
                capturePoster(completion: completion)
            case .capturePosterNamed(let title):
                capturePoster(title: title, completion: completion)
            case .recordStart:
                startRecording(completion: completion)
            case .recordStop:
                try stopRecording(); completion(.success(["recording": false, "saved": false, "cancelled": true])); emitState()
            case .mediaReady:
                let pending = openMediaQueue.markReady()
                completion(.success(["ready": true]))
                if let pending {
                    DispatchQueue.main.async { [weak self] in self?.emitOpenMedia(pending) }
                }
                DispatchQueue.main.async { [weak self] in self?.emitWindowState() }
            case .mediaNotReady:
                openMediaQueue.markNotReady()
                deactivateVideoSurface()
                completion(.success(["ready": false]))
            case .pictureInPicture(let enabled):
                completion(.success(["active": try setPictureInPicture(enabled)]))
            case .getWindowState:
                completion(.success(windowState()))
            }
        } catch { completion(.failure(error)) }
    }

    private func loadLocal(id: String, position: Double?, completion: @escaping (Result<Any, Error>) -> Void) throws {
        let url = try store.resolve(id)
        stopScopedAccess()
        guard NativeMediaFilePolicy.isReadableRegularFile(url) else {
            throw NSError(domain: "AIPlayer.bookmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地媒体不可读，请重新选择文件。"])
        }
        activeScopeStarted = url.startAccessingSecurityScopedResource()
        activeScopedURL = url
        currentMediaSource = url
        do { try beginLoad(location: url.path, position: position, completion: completion) }
        catch { stopScopedAccess(); throw error }
    }

    private func beginLoad(location: String, position: Double?, completion: @escaping (Result<Any, Error>) -> Void) throws {
        processEngineEvents()
        cancelPendingLoad(message: "已由新的媒体加载取代")
        try resetPerMediaState()
        let entryID = try engine.load(location, position: position)
        hasMedia = false
        videoView.isHidden = true
        let started = loadTracker.begin(entryID: entryID)
        let generation = started.token.generation
        let timeout = DispatchWorkItem { [weak self] in self?.timeoutLoad(generation: generation) }
        pendingLoad = PendingLoad(token: started.token, completion: completion, timeout: timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: timeout)
    }

    private func processEngineEvents() {
        for event in engine.drainEvents() {
            guard let resolution = loadTracker.consume(event) else { continue }
            switch resolution {
            case .loaded(let token): completeLoad(token: token)
            case .failed(let token, let code): failLoad(token: token, code: code, message: nil)
            case .timedOut: break
            }
        }
        if engine.ended && mediaTools.isCapturing { mediaTools.finishCapture() }
    }

    private func completeLoad(token: NativeLoadToken) {
        guard let pendingLoad, pendingLoad.token == token else { return }
        pendingLoad.timeout.cancel()
        self.pendingLoad = nil
        hasMedia = true
        videoView.isHidden = !(requestedVisible && engine.rendererReady)
        let current = state(processEvents: false)
        pendingLoad.completion(.success(current))
        emitState(processEvents: false)
    }

    private func failLoad(token: NativeLoadToken, code: Int32, message: String?) {
        guard let pendingLoad, pendingLoad.token == token else { return }
        pendingLoad.timeout.cancel()
        self.pendingLoad = nil
        hasMedia = false
        videoView.isHidden = true
        stopScopedAccess()
        let detail = message ?? (code < 0 ? (aiplayer_mpv_error(code).map { String(cString: $0) } ?? "媒体加载失败") : "媒体在完成加载前已结束")
        let error = MediaToolError.message(detail)
        pendingLoad.completion(.failure(error))
        emitState(error: detail, processEvents: false)
    }

    private func timeoutLoad(generation: UInt64) {
        let resolution = NativeLoadTimeoutCoordinator.resolveAfterDrain(
            drain: { processEngineEvents() },
            timeout: { loadTracker.timeout(generation: generation) }
        )
        guard case .timedOut(let token)? = resolution else { return }
        try? engine.execute(.stop)
        failLoad(token: token, code: 0, message: "媒体在 9 秒内未完成加载")
    }

    private func cancelPendingLoad(message: String) {
        guard let pendingLoad else { return }
        _ = loadTracker.timeout(generation: pendingLoad.token.generation)
        pendingLoad.timeout.cancel()
        self.pendingLoad = nil
        pendingLoad.completion(.failure(MediaToolError.message(message)))
    }

    private func resetPerMediaState() throws {
        try engine.execute(.abLoopA(nil))
        try engine.execute(.abLoopB(nil))
    }

    private func prepareForMediaTransition() throws {
        watchedFrames.reset(); nextWatchedSample = .distantPast
        closeToolWindows()
        posterCapture?.cancel()
        mediaTools.cancelCapture()
        try stopRecording()
    }

    private func stopScopedAccess() {
        if activeScopeStarted { activeScopedURL?.stopAccessingSecurityScopedResource() }
        activeScopeStarted = false
        activeScopedURL = nil
    }

    private func setVideoRectangle(_ rectangle: VideoRectangle) {
        guard let webView, let container = videoView.superview else { return }
        let webBounds = webView.bounds
        // DOM rectangles start at the top. WKWebView is flipped on macOS;
        // convert(_:to:) already accounts for that orientation. Flipping here
        // unconditionally would flip twice and cover the bottom controls.
        let sourceY = webView.isFlipped ? rectangle.y : webBounds.height - rectangle.y - rectangle.height
        var requested = NSRect(x: rectangle.x, y: sourceY, width: rectangle.width, height: rectangle.height)
        requested = requested.intersection(webBounds)
        let converted = webView.convert(requested, to: container)
        requestedVisible = rectangle.visible && !converted.isEmpty && converted.width >= 1 && converted.height >= 1
        videoView.frame = converted.integral
        videoView.isHidden = !(requestedVisible && hasMedia && engine.rendererReady)
    }

    private func importSubtitle(completion: @escaping (Result<Any, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["srt", "vtt", "ass", "ssa", "sub"]
        panel.title = "导入外挂字幕"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { completion(.success(self.state())); return }
            do { try self.engine.addSubtitle(url.path); completion(.success(self.state())) }
            catch { completion(.failure(error)) }
        }
    }

    private func waitForCaptureFrame(_ request: ValidatedNativeRequest, generation: UUID, deadline: Date, completion: @escaping (Result<Any, Error>) -> Void) {
        // time-pos may already show the target while screenshot/OCR still sees
        // the previous decoded frame. Wait asynchronously, never block AppKit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.toolGeneration == generation, self.hasMedia else {
                completion(.failure(MediaToolError.message("媒体已切换，已取消画面处理"))); return
            }
            self.processEngineEvents()
            guard Date() < deadline else {
                completion(.failure(MediaToolError.message("画面定位超时，请稍后重试"))); return
            }
            if self.engine.awaitingDecodedFrame || self.engine.flag("seeking") {
                self.waitForCaptureFrame(request, generation: generation, deadline: deadline, completion: completion)
            } else { self.handle(request, completion: completion) }
        }
    }

    private func saveScreenshot(completion: @escaping (Result<Any, Error>) -> Void) {
        guard hasMedia, posterCapture == nil else { completion(.failure(MediaToolError.message("当前没有可截图的视频或正在生成海报"))); return }
        do {
            let draft = try NativeToolDraft(kind: .screenshot), generation = toolGeneration
            engine.captureFrameAsync(to: draft.fileURL.path) { [weak self] result in
                guard let self, generation == self.toolGeneration else { draft.close(); completion(.success(["cancelled": true, "saved": false])); return }
                switch result {
                case .success: self.saveAndShowPreview(draft, completion: completion)
                case .failure(let error): draft.close(); completion(.failure(error))
                }
            }
        } catch { completion(.failure(error)) }
    }

    private func captureGIF(duration: Double, fps: Int, completion: @escaping (Result<Any, Error>) -> Void) {
        guard hasMedia, posterCapture == nil, let settings = GIFCaptureSettings(duration: duration, fps: fps) else {
            completion(.failure(MediaToolError.message("GIF 参数无效或当前没有媒体")))
            return
        }
        guard !mediaTools.isProcessingGIF, !gifSaving else { completion(.failure(MediaToolError.message("已有 GIF 正在生成"))); return }
        do {
            let draft = try NativeToolDraft(kind: .gif), generation = toolGeneration
            do { try mediaTools.captureGIF(to: draft.fileURL, settings: settings) { [weak self] result in
                guard let self else { draft.close(); return }
                guard generation == self.toolGeneration else { draft.close(); completion(.success(["cancelled": true, "saved": false])); return }
                switch result {
                case .success(let frames): self.saveAndShowPreview(draft, fields: ["frames": frames], showWindow: false, completion: completion)
                case .failure(let error): draft.close(); completion(.failure(error))
                }
            } } catch { draft.close(); throw error }
        } catch { completion(.failure(error)) }
    }

    /// One button starts/stops sampling. All feedback belongs to the existing web
    /// toolstrip; no NSWindow, sheet or save panel is created for GIFs.
    private func startManualGIF(fps: Int, maximumWidth: Int, completion: @escaping (Result<Any, Error>) -> Void) {
        guard hasMedia, posterCapture == nil, !isRecording, !mediaTools.isProcessingGIF, !gifSaving,
              engine.integer("video-params/w") > 0 else {
            completion(.failure(MediaToolError.message("当前没有视频或已有媒体任务正在进行"))); return
        }
        do {
            let draft = try NativeToolDraft(kind: .gif), generation = toolGeneration
            gifSavedName = nil; gifError = nil; gifThumbnail = nil
            // No unused thumbnail: even the first click must not synchronously encode PNG.
            do { try mediaTools.startGIF(to: draft.fileURL, fps: fps, maximumWidth: maximumWidth) { [weak self] result in
                guard let self else { draft.close(); return }
                guard generation == self.toolGeneration else {
                    draft.close(); self.resolveGIFStops(.success(["cancelled": true, "saved": false])); return
                }
                switch result {
                case .success(let frames):
                    self.gifSaving = true
                    self.saveAndShowPreview(draft, fields: ["frames": frames, "duration": self.mediaTools.captureDuration], showWindow: false) { [weak self] saved in
                        guard let self else { return }
                        self.gifSaving = false; self.gifThumbnail = nil
                        if generation == self.toolGeneration {
                            switch saved {
                            case .success(let value): self.gifSavedName = (value as? [String: Any])?["name"] as? String
                            case .failure(let error): self.gifError = error.localizedDescription
                            }
                            self.resolveGIFStops(saved); self.emitState()
                        } else { self.resolveGIFStops(.success(["cancelled": true, "saved": false])) }
                    }
                    self.emitState()
                case .failure(let error):
                    draft.close(); self.gifThumbnail = nil
                    let cancelled = error.localizedDescription == "GIF 生成已取消"
                    if !cancelled { self.gifError = error.localizedDescription }
                    self.resolveGIFStops(cancelled ? .success(["cancelled": true, "saved": false]) : .failure(error))
                    self.emitState()
                }
            } } catch { draft.close(); throw error }
            guard mediaTools.isProcessingGIF else { throw MediaToolError.message(gifError ?? "GIF 无法开始录制") }
            completion(.success(["capturing": true])); emitState()
        } catch { completion(.failure(error)) }
    }

    private func resolveGIFStops(_ result: Result<Any, Error>) {
        let replies = gifStopReplies; gifStopReplies.removeAll()
        replies.forEach { $0(result) }
    }

    @discardableResult func openGIFOutputFolder() throws -> Bool {
        let directory = toolOutputStore.directory(for: .gif)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw MediaToolError.message("无法创建 GIF 成果文件夹，请检查图片目录权限") }
        guard outputFolderOpener(directory) else { throw MediaToolError.message("无法打开 GIF 成果文件夹，请在访达查看“图片/AIPlayer/GIF”") }
        return true
    }

    private func capturePoster(title: String? = nil, completion: @escaping (Result<Any, Error>) -> Void) {
        guard !posterPanelOpen, posterCapture == nil, hasMedia else {
            completion(.failure(MediaToolError.message("当前没有可生成海报的媒体或已有任务正在进行"))); return
        }
        do {
            let draft = try NativeToolDraft(kind: .poster), id = UUID(), generation = toolGeneration
            let progress = NativeCaptureProgressController(title: "正在生成海报…")
            progressWindows[id] = progress
            progress.onCancel = { [weak self] in self?.posterCapture?.cancel() }
            presentToolWindow(progress)
            do { try beginPosterCapture(to: draft.fileURL, title: title) { [weak self] result in
                guard let self else { draft.close(); return }
                progress.finish(); self.progressWindows.removeValue(forKey: id)
                guard generation == self.toolGeneration else { draft.close(); completion(.success(["cancelled": true, "saved": false])); return }
                switch result {
                case .success(let value): self.saveAndShowPreview(draft, fields: value as? [String: Any] ?? [:], completion: completion)
                case .failure(let error): draft.close(); completion(.failure(error))
                }
            } } catch { progress.finish(); progressWindows.removeValue(forKey: id); draft.close(); throw error }
        } catch { completion(.failure(error)) }
    }

    private func presentToolWindow(_ controller: NSWindowController) {
        if let toolPresentation { toolPresentation(controller); return }
        guard let parent = window, let tool = controller.window else { return }
        parent.addChildWindow(tool, ordered: .above)
        tool.setFrameOrigin(NSPoint(x: parent.frame.maxX - tool.frame.width - 64, y: parent.frame.midY - tool.frame.height / 2))
        controller.showWindow(nil)
    }

    private func populateProgressPreview(_ progress: NativeCaptureProgressController, draft: NativeToolDraft) {
        let thumbnail = draft.directory.appendingPathComponent("preview.png")
        engine.captureFrameAsync(to: thumbnail.path) { [weak progress] result in
            if case .success = result { progress?.updatePreview(NSImage(contentsOf: thumbnail)) }
        }
    }

    private func showPreview(_ draft: NativeToolDraft) {
        let id = UUID(), preview = NativeToolPreviewController(draft: draft)
        preview.onClose = { [weak self] in self?.previewWindows.removeValue(forKey: id) }
        previewWindows[id] = preview
        presentToolWindow(preview)
    }

    private func saveAndShowPreview(_ draft: NativeToolDraft, fields: [String: Any] = [:], showWindow: Bool = true, completion: @escaping (Result<Any, Error>) -> Void) {
        let store = toolOutputStore, generation = toolGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try draft.autoSave(using: store) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let output):
                    var response = fields
                    response["saved"] = true; response["name"] = output.lastPathComponent
                    if showWindow, let self, generation == self.toolGeneration {
                        self.showPreview(draft); response["previewOpened"] = true
                    } else { draft.close(); response["previewOpened"] = false }
                    completion(.success(response))
                case .failure:
                    draft.close()
                    completion(.failure(MediaToolError.message("自动保存失败，请检查图片或影片目录的写入权限与磁盘空间")))
                }
            }
        }
    }

    private func closeToolWindows() {
        toolGeneration = UUID()
        mediaTools.cancelCapture()
        gifThumbnail = nil; gifSavedName = nil; gifError = nil
        resolveGIFStops(.success(["cancelled": true, "saved": false]))
        rangeWindow?.close(); rangeWindow = nil
        for progress in Array(progressWindows.values) { progress.close() }
        progressWindows.removeAll()
        for preview in Array(previewWindows.values) { preview.close() }
        previewWindows.removeAll()
    }

    /// Network posters use only watched stills, never seeking into unseen segments.
    /// Local files retain six-point sampling. No source URL reaches the poster.
    func beginPosterCapture(to output: URL, title: String? = nil, completion: @escaping (Result<Any, Error>) -> Void) throws {
        // Streaming seeks may fetch a new HLS segment for every sample. Use
        // the frame the user is actually watching instead of six network seeks.
        let currentFrameOnly = currentMediaSource?.isFileURL == false
        guard hasMedia, posterCapture == nil, !mediaTools.isProcessingGIF, !gifSaving, !isRecording,
              (currentFrameOnly || engine.flag("seekable")), engine.integer("video-params/w") > 0 else {
            throw MediaToolError.message("请使用可定位的视频，并先结束 GIF 或录制任务")
        }
        var metadata = PosterMetadata(title: title ?? engine.string("media-title", fallback: "AIPlayer"),
            duration: engine.double("duration"), width: Int(engine.integer("video-params/w")), height: Int(engine.integer("video-params/h")))
        let position = engine.double("time-pos"), paused = engine.flag("pause")
        let cachedFrames = currentFrameOnly ? watchedFrames.frames.filter { $0.time <= metadata.duration }.sorted { $0.time < $1.time } : []
        let usesWatchedCache = !cachedFrames.isEmpty
        if currentFrameOnly { metadata.captureTimes = usesWatchedCache ? cachedFrames.map(\.time) : [max(0, min(position, metadata.duration))] }
        if currentFrameOnly && !usesWatchedCache && (engine.awaitingDecodedFrame || engine.flag("seeking")) {
            throw MediaToolError.message("请先播放出视频画面，再生成海报")
        }
        let decoder = engine.string("hwdec", fallback: "auto-safe")
        let loopA = engine.double("ab-loop-a", fallback: -1), loopB = engine.double("ab-loop-b", fallback: -1)
        let capture = NativePosterCapture(metadata: metadata, snapshot: { [weak self] target, destination, done in
            guard let self else { done(.failure(MediaToolError.message("播放器已关闭"))); return }
            if let frame = cachedFrames.first(where: { $0.time == target }) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<Void, Error> = Result {
                        guard let png = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) else {
                            throw MediaToolError.message("已观看画面编码失败")
                        }
                        try png.write(to: destination, options: .atomic)
                    }
                    DispatchQueue.main.async { done(result) }
                }
            }
            else if currentFrameOnly { self.engine.captureFrameAsync(to: destination.path, completion: done) }
            else { self.snapshotPosterFrame(at: target, destination: destination, completion: done) }
        }, restore: { [weak self] in
            guard let self else { return }
            self.posterFrameTimer?.invalidate(); self.posterFrameTimer = nil
            if !usesWatchedCache && self.engine.string("hwdec") != decoder { try? self.engine.setFrameCaptureDecoder(decoder) }
            if !currentFrameOnly {
                try? self.engine.execute(.seek(position))
                try? self.engine.execute(.abLoopA(loopA >= 0 ? loopA : nil))
                try? self.engine.execute(.abLoopB(loopB >= 0 ? loopB : nil))
            }
            if !usesWatchedCache { try? self.engine.execute(.pause(paused)) }
        })
        posterCapture = capture
        do {
            if !usesWatchedCache { try engine.execute(.pause(true)) }
            // Zero-copy VideoToolbox frames cannot be converted by libswscale
            // in libmpv screenshots. Copy-back retains hardware decoding while
            // making the decoded frames readable; restore the user's mode later.
            if !usesWatchedCache && decoder != "no" && decoder != "auto-copy" { try engine.setFrameCaptureDecoder("auto-copy") }
            if !currentFrameOnly { try engine.execute(.abLoopA(nil)); try engine.execute(.abLoopB(nil)) }
            try capture.start(to: output) { [weak self] result in
                self?.posterCapture = nil
                self?.emitState()
                completion(result.map { ["saved": true, "frames": $0] })
            }
        } catch {
            posterCapture = nil
            if !usesWatchedCache {
                try? engine.setFrameCaptureDecoder(decoder)
                if !currentFrameOnly {
                    try? engine.execute(.abLoopA(loopA >= 0 ? loopA : nil))
                    try? engine.execute(.abLoopB(loopB >= 0 ? loopB : nil))
                }
                try? engine.execute(.pause(paused))
            }
            throw error
        }
    }

    private func snapshotPosterFrame(at target: Double, destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            // Drain older restart events before issuing this seek. A changed
            // time-pos alone is not proof that the new video frame decoded.
            processEngineEvents()
            let generation = engine.playbackRestartGeneration
            // A frame spans 1/fps seconds. The old fixed one-second gate
            // incorrectly timed out on valid low-frame-rate paused seeks.
            let fps = engine.double("estimated-vf-fps")
            let tolerance = fps > 0 ? max(1, min(60, 1 / fps + 0.1)) : 1
            try engine.execute(.seek(target))
            posterFrameTimer?.invalidate()
            let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] timer in
                guard let self, self.posterCapture != nil else { timer.invalidate(); return }
                self.processEngineEvents()
                guard self.engine.playbackRestartGeneration != generation, !self.engine.flag("seeking"),
                      abs(self.engine.double("time-pos") - target) < tolerance else { return }
                timer.invalidate(); self.posterFrameTimer = nil
                self.engine.captureFrameAsync(to: destination.path, completion: completion)
            }
            posterFrameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch { completion(.failure(error)) }
    }

    private func startRecording(completion: @escaping (Result<Any, Error>) -> Void) {
        guard hasMedia, posterCapture == nil, clipExporter == nil, engine.double("duration") > 0 else {
            completion(.failure(MediaToolError.message("当前没有可定位的视频或已有导出任务"))); return
        }
        if let rangeWindow { presentToolWindow(rangeWindow); completion(.success(["panelOpened": true, "recording": false, "saved": false])); return }
        let panel = NativeRecordingRangeController(position: engine.double("time-pos"), duration: engine.double("duration"))
        rangeWindow = panel
        panel.onStart = { [weak self] range in self?.exportClip(range: range) }
        panel.onClose = { [weak self] in self?.rangeWindow = nil }
        presentToolWindow(panel)
        completion(.success(["panelOpened": true, "recording": false, "saved": false]))
    }

    private func exportClip(range: NativeClipRange) {
        guard clipExporter == nil, hasMedia, let source = currentMediaSource else { emitState(error: "媒体授权已失效或已有导出任务，请重新打开视频"); return }
        do {
            let draft = try NativeToolDraft(kind: .recording), exporter = NativeClipExporter(), id = UUID(), generation = toolGeneration
            let progress = NativeCaptureProgressController(title: "正在导出所选片段…")
            clipExporter = exporter; clipDraft = draft; recording = true
            progressWindows[id] = progress
            progress.onCancel = { [weak self] in try? self?.stopRecording() }
            presentToolWindow(progress); emitState()
            exporter.start(source: source, range: range, to: draft.fileURL) { [weak self] result in
                guard let self else { draft.close(); return }
                progress.finish(); self.progressWindows.removeValue(forKey: id)
                guard self.clipExporter === exporter, generation == self.toolGeneration else { draft.close(); return }
                self.clipExporter = nil; self.clipDraft = nil; self.recording = false
                switch result {
                case .success:
                    self.saveAndShowPreview(draft) { [weak self] result in
                        switch result {
                        case .success: self?.emitState()
                        case .failure(let error): self?.emitState(error: error.localizedDescription)
                        }
                    }
                case .failure(let error): draft.close(); self.emitState(error: error.localizedDescription)
                }
            }
        } catch { emitState(error: "无法创建本机临时导出文件") }
    }

    private func stopRecording() throws {
        clipExporter?.cancel(); clipExporter = nil
        clipDraft?.close(); clipDraft = nil
        guard recording || isRecording else { return }
        try engine.setStreamRecording(to: nil)
        recording = false
    }

    private var isRecording: Bool {
        !engine.string("stream-record").isEmpty
    }

    private func deliverOpenMedia(_ items: [NativeOpenMediaItem]) {
        let isHome = webView?.url?.path == "/"
        if !isHome { openMediaQueue.markNotReady() }
        if let delivery = openMediaQueue.enqueue(items) {
            emitOpenMedia(delivery)
        } else if !isHome, let webView {
            webView.load(URLRequest(url: DesktopPolicy.baseURL))
        }
    }

    private func emitOpenMedia(_ items: [NativeOpenMediaItem]) {
        emit(["event": "openMedia", "items": items.map(\.bridgeValue)])
    }

    private func setPictureInPicture(_ enabled: Bool) throws -> Bool {
        guard let window else { throw MediaToolError.message("播放器窗口不可用") }
        guard !windowTransitionGate.isFullscreenTransitioning else { throw MediaToolError.message("窗口正在切换全屏，请稍后重试") }
        if enabled {
            guard pictureInPictureState == nil else { return true }
            guard !window.styleMask.contains(.fullScreen) else { throw MediaToolError.message("请先退出全屏，再开启小窗") }
            pictureInPictureState = (window.frame, window.minSize, window.level, window.collectionBehavior)
            window.minSize = NSSize(width: 320, height: 200)
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let size = NSSize(width: min(420, visible.width), height: min(260, visible.height))
            let origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20)
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
            window.makeKeyAndOrderFront(nil)
            emitWindowState()
            return true
        }
        guard let saved = pictureInPictureState else { return false }
        pictureInPictureState = nil
        window.level = saved.level
        window.collectionBehavior = saved.collectionBehavior
        window.minSize = saved.minimumSize
        window.setFrame(saved.frame, display: true, animate: true)
        emitWindowState()
        return false
    }

    private func observeWindowState(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                _ = self?.windowTransitionGate.beginFullscreenTransition()
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.windowTransitionGate.finishFullscreenTransition()
                self?.emitWindowState()
            })
        }
    }

    private func toggleFullscreen(completion: @escaping (Result<Any, Error>) -> Void) {
        guard let window else { completion(.failure(MediaToolError.message("播放器窗口不可用"))); return }
        guard pictureInPictureState == nil else { completion(.failure(MediaToolError.message("请先退出小窗，再切换全屏"))); return }
        guard windowTransitionGate.beginFullscreenTransition() else {
            var current = windowState()
            current["transitioning"] = true
            completion(.success(current))
            return
        }
        window.toggleFullScreen(nil)
        var current = windowState()
        current["transitioning"] = windowTransitionGate.isFullscreenTransitioning
        completion(.success(current))
    }

    func toggleFullscreenFromMenu() {
        toggleFullscreen { _ in }
    }

    private func windowState() -> [String: Any] {
        [
            "fullscreen": window?.styleMask.contains(.fullScreen) ?? false,
            "pictureInPicture": pictureInPictureState != nil
        ]
    }

    private func emitWindowState() {
        var detail = windowState()
        detail["event"] = "windowState"
        emit(detail)
    }

    private func capabilities() -> [String: Any] {
        [
            "available": engine.rendererReady,
            "engine": engine.string("mpv-version", fallback: "libmpv"),
            "commands": ["pause", "seek", "volume", "mute", "speed", "audioTrack", "subtitleTrack", "subtitleDelay", "audioDelay", "aspect", "rotation", "brightness", "contrast", "saturation", "gamma", "hue", "abLoopA", "abLoopB", "loop", "deinterlace", "hwdec", "frameStep", "frameBackStep", "stop", "ocr", "captureGif", "gifStart", "gifStop", "gifCancel", "openGifFolder", "capturePoster", "recordStart", "recordStop", "mediaReady", "mediaNotReady", "pictureInPicture", "getWindowState"],
            "openFiles": true,
            "importSubtitle": true,
            "screenshot": true,
            "fullscreen": true
        ]
    }

    private func state(processEvents: Bool = true) -> [String: Any] {
        if processEvents { processEngineEvents() }
        playbackPower.update(enabled: keepAwakeEnabled,
                             playing: hasMedia && !engine.flag("pause", fallback: true)
                                && !engine.flag("idle-active", fallback: true) && !engine.ended && engine.lastError == nil)
        let tracks = (0..<max(0, Int(engine.integer("track-list/count")))).map { index -> [String: Any] in
            let prefix = "track-list/\(index)/"
            var track: [String: Any] = [
                "id": Int(engine.integer(prefix + "id")),
                "type": engine.string(prefix + "type"),
                "selected": engine.flag(prefix + "selected"),
                "external": engine.flag(prefix + "external")
            ]
            let title = engine.string(prefix + "title"); if !title.isEmpty { track["title"] = title }
            let lang = engine.string(prefix + "lang"); if !lang.isEmpty { track["lang"] = lang }
            return track
        }
        let chapters = (0..<max(0, Int(engine.integer("chapter-list/count")))).map { index -> [String: Any] in
            let prefix = "chapter-list/\(index)/"
            return ["time": engine.double(prefix + "time"), "title": engine.string(prefix + "title", fallback: "章节 \(index + 1)")]
        }
        var result: [String: Any] = [
            "available": engine.rendererReady,
            "engine": engine.string("mpv-version", fallback: "libmpv"),
            "paused": engine.flag("pause", fallback: true),
            "keepAwake": keepAwakeEnabled,
            "displayAwake": playbackPower.isActive,
            "time": engine.double("time-pos"),
            "duration": engine.double("duration"),
            "volume": engine.double("volume", fallback: 100),
            "speed": engine.double("speed", fallback: 1),
            "muted": engine.flag("mute"),
            "title": engine.string("media-title"),
            "tracks": tracks,
            "chapters": chapters,
            "width": Int(engine.integer("video-params/w")),
            "height": Int(engine.integer("video-params/h")),
            "subtitleDelay": engine.double("sub-delay"),
            "audioDelay": engine.double("audio-delay"),
            "ended": engine.ended,
            "recording": recording || isRecording,
            "exporting": clipExporter != nil,
            "gifCapturing": mediaTools.isCapturing,
            "gifExporting": gifSaving || (mediaTools.isProcessingGIF && !mediaTools.isCapturing),
            "gifElapsed": mediaTools.captureDuration
        ]
        if let gifSavedName { result["gifSavedName"] = gifSavedName }
        if let gifError { result["gifError"] = gifError }
        if let gifThumbnail { result["gifThumbnail"] = gifThumbnail }
        if let error = engine.lastError { result["error"] = error }
        return result
    }

    private func emitState(error: String? = nil, processEvents: Bool = true) {
        var value = state(processEvents: processEvents)
        sampleWatchedFrame()
        if let error { value["error"] = error }
        emit(["event": "state", "state": value])
    }

    private func sampleWatchedFrame() {
        guard currentMediaSource?.isFileURL == false, hasMedia, requestedVisible,
              !engine.flag("pause"), !engine.flag("seeking"), !engine.awaitingDecodedFrame,
              posterCapture == nil, !mediaTools.isProcessingGIF, !isRecording,
              Date() >= nextWatchedSample else { return }
        let time = engine.double("time-pos", fallback: -1)
        guard time > 0, let token = watchedFrames.beginSample(at: time) else { return }
        nextWatchedSample = Date().addingTimeInterval(1)
        let generation = toolGeneration, restart = engine.playbackRestartGeneration
        videoView.captureGIFFrame(maximumWidth: 1200) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.toolGeneration, self.hasMedia, self.requestedVisible,
                      !self.engine.flag("seeking"), !self.engine.awaitingDecodedFrame,
                      restart == self.engine.playbackRestartGeneration,
                      abs(self.engine.double("time-pos") - time) < 1 else { self.watchedFrames.fail(token); return }
                do { try self.watchedFrames.complete(token, at: time, image: result.get()) }
                catch { self.watchedFrames.fail(token) }
            }
        }
    }

    func emitErrorState(_ error: Error) {
        emitState(error: error.localizedDescription)
    }

    func emit(_ detail: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(detail), let data = try? JSONSerialization.data(withJSONObject: detail), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('aiplayer:native',{detail:\(json)}))")
    }
}

final class DropContainerView: NSView {
    var onFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let values = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !values.isEmpty else { return false }
        onFiles?(values)
        return true
    }
}

final class PlayerWebView: WKWebView {
    var onFiles: (([URL]) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let values = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !values.isEmpty {
            onFiles?(values)
            return true
        }
        return super.performDragOperation(sender)
    }
}
