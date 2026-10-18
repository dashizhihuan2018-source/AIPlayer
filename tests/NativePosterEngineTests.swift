import AppKit
import Foundation
import ImageIO
import WebKit

@main struct NativePosterEngineTests {
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else { fatalError("usage: NativePosterEngineTests <owned-test-video> [owned-test-output.png]") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-poster-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView = container
        let web = WKWebView(frame: container.bounds)
        container.addSubview(web)
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: directory)
        defer { player.shutdown() }
        try player.engine.execute(.mute(true))
        try player.engine.execute(.pause(true))
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        var load: Result<Any, Error>?
        player.handle(.loadURL(fixture, position: 2)) { load = $0 }
        try awaitResult({ load }, timeout: 10).get()
        player.handle(.setVideoRect(VideoRectangle(x: 0, y: 0, width: 960, height: 540, visible: true))) { _ in }
        // Paused seeks need decoded-frame completion, not just load acceptance.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let screenshot = directory.appendingPathComponent("current-frame.png")
        do { try player.engine.screenshot(to: screenshot.path) }
        catch { print("FAIL default hardware decoding must allow real screenshots (mpv code \((error as NSError).code))"); exit(1) }
        precondition(CGImageSourceCreateWithURL(screenshot as CFURL, nil) != nil)
        try player.engine.execute(.hwdec(false)); try player.engine.execute(.hwdec(true))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try player.engine.screenshot(to: screenshot.path)
        let tools = NativeMediaTools { try player.engine.screenshot(to: $0.path) }
        let recognized = try tools.recognizeCurrentFrame()
        precondition(recognized.filter(\.isNumber).count >= 4, "Vision must recognize the owned test video's burned-in timecode")
        try player.engine.execute(.pause(false))
        var gif: Result<Int, Error>?
        let gifURL = directory.appendingPathComponent("actual-video.gif")
        try tools.captureGIF(to: gifURL, settings: GIFCaptureSettings(duration: 0.4, fps: 5)!) { gif = $0 }
        let gifCount = try awaitResult({ gif }, timeout: 4).get()
        precondition(gifCount == 2 && CGImageSourceGetCount(CGImageSourceCreateWithURL(gifURL as CFURL, nil)!) == 2)
        try player.engine.execute(.pause(true))
        let before = player.engine.double("time-pos")
        let decoder = player.engine.string("hwdec")
        let output = directory.appendingPathComponent("poster.png")
        var poster: Result<Any, Error>?
        try player.beginPosterCapture(to: output) { poster = $0 }
        do { _ = try awaitResult({ poster }, timeout: 30).get() }
        catch {
            print("Poster integration failure: engine=\(player.engine.lastError ?? "none"), time=\(player.engine.double("time-pos")), restarts=\(player.engine.playbackRestartGeneration)")
            throw error
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(player.engine.flag("pause"), "poster must restore the paused state")
        precondition(abs(player.engine.double("time-pos") - before) < 0.2, "poster must restore the original position")
        precondition(player.engine.string("hwdec") == decoder, "poster must restore the user's hardware decoder mode")
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == 1200 && image.height == 620)
        if CommandLine.arguments.count == 3 {
            try Data(contentsOf: output).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        }

        // A playing video and an existing A/B loop must also resume correctly.
        try player.engine.execute(.abLoopA(1)); try player.engine.execute(.abLoopB(10))
        try player.engine.execute(.pause(false))
        let playingPosition = player.engine.double("time-pos")
        var playingPoster: Result<Any, Error>?
        try player.beginPosterCapture(to: directory.appendingPathComponent("playing-poster.png")) { playingPoster = $0 }
        _ = try awaitResult({ playingPoster }, timeout: 30).get()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(!player.engine.flag("pause"), "poster must restore active playback")
        precondition(abs(player.engine.double("time-pos") - playingPosition) < 0.7)
        precondition(abs(player.engine.double("ab-loop-a") - 1) < 0.01 && abs(player.engine.double("ab-loop-b") - 10) < 0.01)
        precondition(player.engine.string("hwdec") == decoder)
        try player.engine.execute(.pause(true)); try player.engine.execute(.abLoopA(nil)); try player.engine.execute(.abLoopB(nil))

        // Cancellation through the ordinary stop command must abort first and
        // must not let a delayed frame callback restart the stopped media.
        let protected = directory.appendingPathComponent("protected.png")
        let sentinel = Data("user-existing-output".utf8)
        try sentinel.write(to: protected)
        var cancelled: Result<Any, Error>?
        try player.beginPosterCapture(to: protected) { cancelled = $0 }
        player.handle(.engine(.stop)) { _ in }
        guard case .failure? = cancelled else { fatalError("stop did not cancel poster") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let preserved = try Data(contentsOf: protected)
        precondition(preserved == sentinel)
        print("Native libmpv media tools: default/toggled HW screenshot, real timecode OCR, two-frame GIF, six-frame poster, position/pause/decoder/AB restore and stop cancellation PASS")
    }

    private static func awaitResult<T>(_ read: () -> Result<T, Error>?, timeout: TimeInterval) throws -> Result<T, Error> {
        let deadline = Date().addingTimeInterval(timeout)
        while read() == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let result = read() else { throw MediaToolError.message("owned media test timed out") }
        return result
    }
}
