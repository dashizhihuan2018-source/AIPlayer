import AppKit
import Foundation

@main struct NativeToolWindowLayoutTests {
    static func main() throws {
        _ = NSApplication.shared
        var failures: [String] = []
        for kind: NativeToolDraftKind in [.screenshot, .gif, .poster] {
            let draft = try NativeToolDraft(kind: kind)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3840, pixelsHigh: 2160,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            if kind == .gif {
                let writer = try GIFFrameWriter(url: draft.fileURL, frameCount: 2, fps: 10)
                try writer.append(bitmap.cgImage!); try writer.append(bitmap.cgImage!); try writer.finish()
            } else {
                try bitmap.representation(using: .png, properties: [:])!.write(to: draft.fileURL)
            }
            let preview = NativeToolPreviewController(draft: draft)
            let window = preview.window!
            showAndLayout(window)
            print("\(kind.rawValue) shown frame: \(window.frame.size)")
            if window.frame.width > 400 || window.frame.height > 400 { failures.append("\(kind.rawValue) preview expanded to its image dimensions") }
            let images = allViews(window.contentView!).compactMap { $0 as? NSImageView }
            if images.first?.image == nil { failures.append("\(kind.rawValue) image failed to decode") }
            preview.close()
            if FileManager.default.fileExists(atPath: draft.directory.path) { failures.append("\(kind.rawValue) preview failed to discard its draft") }
        }
        let largeImage = NSImage(size: NSSize(width: 3840, height: 2160))
        let progress = NativeCaptureProgressController(title: "GIF 采样中", preview: largeImage)
        showAndLayout(progress.window!)
        progress.update("正在采样 0.5 / 10.0 秒 · 15 fps")
        progress.updatePreview(NSImage(size: NSSize(width: 7680, height: 4320)))
        settle(progress.window!)
        print("progress shown frame: \(progress.window!.frame.size)")
        if progress.window!.frame.width > 320 || progress.window!.frame.height > 300 { failures.append("progress preview expanded to its image dimensions") }
        progress.finish()
        let range = NativeRecordingRangeController(position: 604_780, duration: 604_800)
        showAndLayout(range.window!)
        print("recording range shown frame: \(range.window!.frame.size)")
        if range.window!.frame.width > 360 || range.window!.frame.height > 350 { failures.append("recording range unexpectedly expanded") }
        for button in allViews(range.window!.contentView!).compactMap({ $0 as? NSButton }) where !button.isHidden {
            let rect = button.convert(button.bounds, to: range.window!.contentView!)
            if !range.window!.contentView!.bounds.contains(rect) { failures.append("recording range button clipped: \(button.title)") }
        }
        range.close()
        if CommandLine.arguments.count > 1 {
            let draft = try NativeToolDraft(kind: .recording)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: draft.fileURL)
            let preview = NativeToolPreviewController(draft: draft)
            showAndLayout(preview.window!)
            print("recording preview shown frame: \(preview.window!.frame.size)")
            if preview.window!.frame.width > 400 || preview.window!.frame.height > 400 { failures.append("recording preview unexpectedly expanded") }
            preview.close()
        }
        guard failures.isEmpty else { print("FAIL " + failures.joined(separator: "; ")); exit(1) }
        print("Native tool windows: full-resolution images stay in compact shown windows PASS")
    }
    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    private static func showAndLayout(_ window: NSWindow) {
        // Only these test-owned, transparent, offscreen windows are ordered;
        // never activate the app or make a window key while a GUI test runs.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        settle(window)
        precondition(window.isVisible)
    }
    private static func settle(_ window: NSWindow) {
        window.contentView!.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView!.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
}
