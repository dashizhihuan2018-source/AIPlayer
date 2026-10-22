import AppKit
import Foundation
import ImageIO
import Vision
import WebKit

/// Only accepts explicitly supplied, owned fixtures; never reads the user's queue.
@main struct NativeMoviePosterTests {
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-movie-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView = container
        let web = WKWebView(frame: container.bounds)
        container.addSubview(web)
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: root)
        defer { player.shutdown() }
        try player.engine.execute(.mute(true)); try player.engine.execute(.pause(true))
        var loaded: Result<Any, Error>?
        player.handle(.loadURL(URL(fileURLWithPath: CommandLine.arguments[1]), position: 0)) { loaded = $0 }
        _ = try wait({ loaded }).get()
        player.handle(.setVideoRect(VideoRectangle(x: 0, y: 0, width: 960, height: 540, visible: true))) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let output = root.appendingPathComponent("movie.png")
        var poster: Result<Any, Error>?
        try player.beginPosterCapture(to: output) { poster = $0 }
        do { _ = try wait({ poster }).get() }
        catch {
            print("FAIL poster capture: \(error.localizedDescription); decoded position=\(player.engine.double("time-pos")); fps=\(player.engine.double("estimated-vf-fps"))")
            exit(1)
        }
        precondition(player.engine.flag("pause"))
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == 1200 && image.height == 1800)
        let qr = VNDetectBarcodesRequest(); qr.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([qr])
        precondition(qr.results?.contains { $0.payloadStringValue == "https://github.com/dashizhihuan2018-source/AIPlayer" } == true)
        if CommandLine.arguments.count > 2 {
            try Data(contentsOf: output).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("Native movie poster: actual decoded frames, isolated capture and paused restore PASS")
    }

    private static func wait(_ read: () -> Result<Any, Error>?) throws -> Result<Any, Error> {
        let end = Date().addingTimeInterval(30)
        while read() == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let value = read() else { throw MediaToolError.message("poster test deadline exceeded") }
        return value
    }
}
