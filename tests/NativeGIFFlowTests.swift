import AppKit
import Foundation
import ImageIO
import WebKit

@main struct NativeGIFFlowTests {
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-gif-flow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds); window.contentView = container
        let web = WKWebView(frame: container.bounds); container.addSubview(web)
        var presented = 0
        var openedFolders: [URL] = []
        let outputStore = NativeToolOutputStore(homeDirectory: root.appendingPathComponent("home"))
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: root, toolPresentation: { _ in presented += 1 }, toolOutputStore: outputStore, outputFolderOpener: { openedFolders.append($0); return true })
        defer { player.shutdown() }
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
            var result: Result<Any, Error>?
            player.handle(try NativeBridgePolicy.validateRequest(command: name, args: args, authorizedLocalIDs: [])) { result = $0 }
            let deadline = Date().addingTimeInterval(30)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            guard let result else { throw MediaToolError.message("GIF integration timed out") }
            return try result.get() as! [String: Any]
        }
        func load(_ position: Double, source: String = CommandLine.arguments[1]) throws {
            var result: Result<Any, Error>?
            player.handle(.loadURL(URL(fileURLWithPath: source), position: position)) { result = $0 }
            let deadline = Date().addingTimeInterval(10)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            _ = try result!.get()
        }
        try player.engine.execute(.pause(true)); try player.engine.execute(.mute(true))
        let folderResult = try call("openGifFolder")
        precondition(folderResult["opened"] as? Bool == true && openedFolders == [outputStore.directory(for: .gif)], "folder route must work without loaded media and open only the configured output directory")
        try load(2)
        let referenceURL = root.appendingPathComponent("reference.png")
        let referenceDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: referenceURL.path) && Date() < referenceDeadline {
            do { try player.engine.screenshot(to: referenceURL.path) }
            catch { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let referenceSource = CGImageSourceCreateWithURL(referenceURL as CFURL, nil)!
        let referenceImage = try NativeMediaTools.resized(CGImageSourceCreateImageAtIndex(referenceSource, 0, nil)!, maximumWidth: 640)
        let started = try call("gifStart", ["fps": 5, "maximumWidth": 640])
        precondition(started["capturing"] as? Bool == true)
        RunLoop.main.run(until: Date().addingTimeInterval(3.3))
        let active = try call("getState")
        precondition(active["gifCapturing"] as? Bool == true, "GIF must not stop after 3 seconds")
        precondition((active["gifElapsed"] as? Double ?? 0) > 3)
        precondition(active["gifThumbnail"] == nil, "no synchronous thumbnail work for a text-only GIF UI")
        precondition(active["paused"] as? Bool == true, "GIF must not silently toggle playback")
        let saved = try call("gifStop")
        precondition(saved["saved"] as? Bool == true && saved["previewOpened"] as? Bool == false)
        precondition(presented == 0, "GIF start/stop must never open a progress/preview/save window")
        let name = saved["name"] as! String
        precondition(!name.contains("/"))
        let file = outputStore.directory(for: .gif).appendingPathComponent(name)
        let source = CGImageSourceCreateWithURL(file as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == 640 && image.height == 360, "default GIF must use 640px")
        let actualBitmap = NSBitmapImageRep(cgImage: image), referenceBitmap = NSBitmapImageRep(cgImage: referenceImage)
        var uprightError = 0.0, invertedError = 0.0
        for y in stride(from: 10, to: image.height - 10, by: 17) {
            for x in stride(from: 10, to: image.width - 10, by: 23) {
                let actual = actualBitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let expected = referenceBitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let inverted = referenceBitmap.colorAt(x: x, y: image.height - 1 - y)!.usingColorSpace(.deviceRGB)!
                uprightError += abs(actual.redComponent - expected.redComponent) + abs(actual.greenComponent - expected.greenComponent) + abs(actual.blueComponent - expected.blueComponent)
                invertedError += abs(actual.redComponent - inverted.redComponent) + abs(actual.greenComponent - inverted.greenComponent) + abs(actual.blueComponent - inverted.blueComponent)
            }
        }
        print("GIF ORIENTATION upright=\(uprightError) inverted=\(invertedError)"); fflush(stdout)
        precondition(uprightError < invertedError * 0.8, "GPU GIF must retain source orientation/colors instead of upside-down or black frames")
        precondition(CGImageSourceGetCount(source) >= 16)
        _ = try call("gifStart", ["fps": 5, "maximumWidth": 640]); _ = try call("gifCancel")
        let files = try FileManager.default.contentsOfDirectory(at: outputStore.directory(for: .gif), includingPropertiesForKeys: nil)
        precondition(files.count == 1, "cancel must not publish a second GIF")
        _ = try call("gifStart", ["fps": 5, "maximumWidth": 3840])
        player.pageWillNavigate()
        let navigated = try call("getState")
        precondition(navigated["gifCapturing"] as? Bool == false, "navigation must cancel capture")
        precondition(presented == 0)
        try load(max(0, player.engine.double("duration") - 0.5))
        try player.engine.execute(.pause(false))
        _ = try call("gifStart", ["fps": 5, "maximumWidth": 640])
        let deadline = Date().addingTimeInterval(15)
        var ended: [String: Any] = [:]
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); ended = try call("getState") }
        while ended["gifSavedName"] as? String == nil && Date() < deadline
        precondition(ended["gifSavedName"] as? String != nil && ended["gifCapturing"] as? Bool == false, "EOF must finalize rather than sample the last frame forever")
        precondition(presented == 0)
        if CommandLine.arguments.count > 2 {
            try player.engine.execute(.pause(false))
            try load(0, source: CommandLine.arguments[2])
            _ = try call("gifStart", ["fps": 5, "maximumWidth": 3840])
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let fourK = try call("gifStop")
            let fourKFile = outputStore.directory(for: .gif).appendingPathComponent(fourK["name"] as! String)
            let fourKSource = CGImageSourceCreateWithURL(fourKFile as CFURL, nil)!
            let fourKImage = CGImageSourceCreateImageAtIndex(fourKSource, 0, nil)!
            precondition(fourKImage.width == 3840 && fourKImage.height == 2160 && CGImageSourceGetCount(fourKSource) >= 2, "actual 4K video must export decodable 4K GIF, not an upscaled thumbnail")
            precondition(presented == 0)
            print("Native GIF real 3840×2160 video → decoded 3840×2160 GIF PASS")
        }
        print("Native GIF routes: >3s manual stop, default640, unchanged pause, no windows, safe folder route, cancel/navigation/EOF PASS")
    }
}
