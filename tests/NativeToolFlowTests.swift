import AppKit
import Foundation
import ImageIO
import WebKit

@main struct NativeToolFlowTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: NativeToolFlowTests <owned-test-video>") }
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-flow-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView = container
        let web = WKWebView(frame: container.bounds)
        container.addSubview(web)
        var presented: [NSWindowController] = []
        let outputStore = NativeToolOutputStore(homeDirectory: support.appendingPathComponent("test-home"))
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: support, toolPresentation: { presented.append($0) }, toolOutputStore: outputStore)
        try player.engine.execute(.mute(true)); try player.engine.execute(.pause(true))
        var loaded: Result<Any, Error>?
        player.handle(.loadURL(URL(fileURLWithPath: CommandLine.arguments[1]), position: 2)) { loaded = $0 }
        _ = try wait({ loaded }).get()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        for request in [ValidatedNativeRequest.screenshot, .captureGIF(duration: 0.2, fps: 10), .capturePoster] {
            var result: Result<Any, Error>?
            player.handle(request) { result = $0 }
            let value = try wait({ result }).get() as! [String: Any]
            if case .captureGIF = request {
                precondition(value["saved"] as? Bool == true && value["previewOpened"] as? Bool == false, "GIF must save without a preview window")
                continue
            }
            guard value["previewOpened"] as? Bool == true && value["saved"] as? Bool == true else { print("FAIL actual tool must auto-save before showing its compact preview"); exit(1) }
            precondition((value["name"] as? String)?.contains("/") == false, "bridge must expose only the generated filename")
            let preview = presented.last as! NativeToolPreviewController
            precondition(!preview.window!.isVisible && !preview.window!.isSheet)
            precondition(CGImageSourceCreateWithURL(preview.draft.fileURL as CFURL, nil) != nil, "preview must own an actual generated image")
            precondition(preview.draft.savedURL != nil && FileManager.default.fileExists(atPath: preview.draft.savedURL!.path))
        }
        var rangeResult: Result<Any, Error>?
        player.handle(.recordStart) { rangeResult = $0 }
        let opened = try rangeResult!.get() as! [String: Any]
        precondition(opened["panelOpened"] as? Bool == true && opened["recording"] as? Bool == false)
        precondition(presented.last is NativeRecordingRangeController)
        var state: Result<Any, Error>?
        player.handle(.getState) { state = $0 }
        let current = try state!.get() as! [String: Any]
        precondition(current["recording"] as? Bool == false, "opening a range panel must not start recording")
        let rangePanel = presented.last as! NativeRecordingRangeController
        let rangeViews = allViews(rangePanel.window!.contentView!)
        for field in rangeViews.compactMap({ $0 as? NSTextField }) {
            if field.identifier?.rawValue == "clip-start" { field.stringValue = "2" }
            if field.identifier?.rawValue == "clip-end" { field.stringValue = "5" }
        }
        rangeViews.compactMap { $0 as? NSButton }.first { $0.title == "开始" }!.performClick(nil)
        let deadline = Date().addingTimeInterval(30)
        while !(presented.last is NativeToolPreviewController) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let clip = presented.last as! NativeToolPreviewController
        precondition(clip.draft.kind == .recording && clip.draft.savedURL?.deletingLastPathComponent() == outputStore.directory(for: .recording), "range export must automatically save the actual MP4")
        // A directory write error must reject the request, not open a card or
        // claim saved:true. This affects only the isolated test-home directory.
        let screenshots = outputStore.directory(for: .screenshot)
        let backup = screenshots.appendingPathExtension("test-backup")
        try FileManager.default.moveItem(at: screenshots, to: backup)
        try Data("test write blocker".utf8).write(to: screenshots)
        let countBeforeFailure = presented.count
        var failedSave: Result<Any, Error>?
        player.handle(.screenshot) { failedSave = $0 }
        switch try wait({ failedSave }) { case .success: fatalError("automatic-save failure falsely reported success"); case .failure: break }
        precondition(presented.count == countBeforeFailure, "save failure must not open a preview or save panel")
        try FileManager.default.removeItem(at: screenshots)
        try FileManager.default.moveItem(at: backup, to: screenshots)
        let directories = presented.compactMap { ($0 as? NativeToolPreviewController)?.draft.directory }
        let savedFiles = presented.compactMap { ($0 as? NativeToolPreviewController)?.draft.savedURL }
        player.shutdown()
        precondition(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "shutdown must discard preview temp files")
        precondition(savedFiles.count == 3 && savedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "shutdown must keep automatic captures")
        print("Native tool flow: actual screenshot/GIF/poster/MP4 automatic save, name-only results, range Start, write-error rejection and saved-file retention PASS")
    }
    private static func wait(_ read: () -> Result<Any, Error>?) throws -> Result<Any, Error> {
        let deadline = Date().addingTimeInterval(30)
        while read() == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let result = read() else { throw MediaToolError.message("owned tool-flow test timed out") }
        return result
    }
    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
