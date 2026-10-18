import AppKit
import Foundation

@main struct NativeToolAutoSaveTests {
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-auto-save-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeToolOutputStore(homeDirectory: root)
        let expected: [NativeToolDraftKind: String] = [.screenshot: "Pictures/AIPlayer/Screenshots", .gif: "Pictures/AIPlayer/GIF", .poster: "Pictures/AIPlayer/Posters", .recording: "Movies/AIPlayer/Clips"]
        for kind: NativeToolDraftKind in [.screenshot, .gif, .poster, .recording] {
            let draft = try NativeToolDraft(kind: kind)
            let bytes = Data("owned \(kind.rawValue) output".utf8)
            try bytes.write(to: draft.fileURL)
            let output = try draft.autoSave(using: store)
            precondition(output.deletingLastPathComponent() == root.appendingPathComponent(expected[kind]!, isDirectory: true))
            precondition(output.lastPathComponent.hasPrefix("AIPlayer-\(kind.rawValue)-") && output.pathExtension == kind.fileExtension)
            precondition(draft.savedURL == output)
            let preview = NativeToolPreviewController(draft: draft)
            let titles = allViews(preview.window!.contentView!).compactMap { ($0 as? NSButton)?.title }
            precondition(titles.contains("打开文件") && titles.contains("打开文件夹") && titles.contains("关闭"))
            precondition(!titles.contains("另存为…") && !titles.contains("丢弃"))
            preview.close()
            precondition(!FileManager.default.fileExists(atPath: draft.directory.path))
            let persisted = try Data(contentsOf: output)
            precondition(persisted == bytes, "closing an automatically saved preview must preserve its output")
        }
        // The same generated filename must never overwrite an existing capture.
        var identifiers = ["collision", "collision", "unique"]
        let collisions = NativeToolOutputStore(homeDirectory: root, identifier: { identifiers.removeFirst() })
        let first = try NativeToolDraft(kind: .screenshot), second = try NativeToolDraft(kind: .screenshot)
        try Data("first".utf8).write(to: first.fileURL); try Data("second".utf8).write(to: second.fileURL)
        let firstOutput = try first.autoSave(using: collisions), secondOutput = try second.autoSave(using: collisions)
        precondition(firstOutput != secondOutput)
        let preserved = try Data(contentsOf: firstOutput)
        precondition(preserved == Data("first".utf8))
        let badRoot = root.appendingPathComponent("not-a-folder")
        try Data("sentinel".utf8).write(to: badRoot)
        let failed = try NativeToolDraft(kind: .poster)
        try Data("output".utf8).write(to: failed.fileURL)
        do { _ = try failed.autoSave(using: NativeToolOutputStore(homeDirectory: badRoot)); fatalError("invalid output root accepted") } catch {}
        precondition(failed.savedURL == nil, "failed save must never claim a saved file")
        first.close(); second.close(); failed.close()
        print("Native automatic save: categorized directories, collision safety, failure state, retained files and no save card PASS")
    }
    private static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
