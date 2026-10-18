import AppKit
import Foundation

@main struct NativeToolDraftTests {
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-draft-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = try NativeToolDraft(kind: .screenshot)
        let bytes = Data("owned-preview-output".utf8)
        try bytes.write(to: draft.fileURL)
        let output = directory.appendingPathComponent("explicit-save.png")
        do { try draft.save(to: output) }
        catch { print("FAIL explicit preview save must copy actual generated output"); exit(1) }
        let saved = try Data(contentsOf: output)
        precondition(saved == bytes)
        draft.close()
        precondition(!FileManager.default.fileExists(atPath: draft.directory.path))
        precondition(FileManager.default.fileExists(atPath: output.path))
        let cancelled = try NativeToolDraft(kind: .poster)
        try bytes.write(to: cancelled.fileURL)
        cancelled.close()
        precondition(!FileManager.default.fileExists(atPath: cancelled.directory.path))
        let missing = try NativeToolDraft(kind: .gif)
        let sentinel = Data("existing-user-file".utf8)
        try sentinel.write(to: output)
        do { try missing.save(to: output); fatalError("missing draft accepted") } catch {}
        let preserved = try Data(contentsOf: output)
        precondition(preserved == sentinel)
        let replacement = try NativeToolDraft(kind: .gif)
        try bytes.write(to: replacement.fileURL)
        try replacement.save(to: output)
        let replaced = try Data(contentsOf: output)
        precondition(replaced == bytes)
        do { try replacement.save(to: replacement.fileURL); fatalError("saving inside disposable draft directory accepted") } catch {}
        let pngDraft = try NativeToolDraft(kind: .screenshot)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: pngDraft.fileURL)
        let preview = NativeToolPreviewController(draft: pngDraft)
        precondition(preview.window!.frame.width <= 360 && !preview.window!.isVisible && !preview.window!.isSheet)
        let views = allViews(preview.window!.contentView!)
        let titles = views.compactMap { ($0 as? NSButton)?.title }
        precondition(titles.contains("复制") && titles.contains("打开文件") && titles.contains("打开文件夹") && titles.contains("关闭") && !titles.contains("另存为…"))
        precondition(views.compactMap { $0 as? NSImageView }.first?.image != nil)
        let range = NativeRecordingRangeController(position: 2, duration: 18)
        let rangeViews = allViews(range.window!.contentView!)
        precondition(rangeViews.compactMap { ($0 as? NSButton)?.title }.contains("开始"))
        precondition(rangeViews.compactMap { $0 as? NSButton }.contains { $0.title.contains("烧录字幕") && !$0.isEnabled })
        let progress = NativeCaptureProgressController(title: "GIF 采样中")
        precondition(!progress.window!.isVisible && allViews(progress.window!.contentView!).compactMap { ($0 as? NSButton)?.title }.contains("取消"))
        print("Native tool draft: explicit save, output preservation and cancel cleanup PASS")
    }
    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
