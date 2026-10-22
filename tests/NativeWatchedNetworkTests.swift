import AppKit
import Foundation
import ImageIO
import Vision
import WebKit

/// Controlled loopback server and owned test-pattern media only.
@main struct NativeWatchedNetworkTests {
    static func main() throws {
        _ = NSApplication.shared
        let base = URL(string: "http://127.0.0.1:19785")!
        _ = try Data(contentsOf: base.appendingPathComponent("online"))
        defer { _ = try? Data(contentsOf: base.appendingPathComponent("online")) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-watched-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds); window.contentView = container
        let web = WKWebView(frame: container.bounds); container.addSubview(web)
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: root)
        defer { player.shutdown() }
        try player.engine.execute(.mute(true)); try player.engine.execute(.pause(false))
        var loaded: Result<Any, Error>?
        player.handle(.loadURL(base.appendingPathComponent("index.m3u8"), position: 0)) { loaded = $0 }
        try spin(until: { loaded != nil }, seconds: 20, label: "initial load")
        _ = try loaded!.get()
        player.handle(.setVideoRect(VideoRectangle(x: 0, y: 0, width: 960, height: 540, visible: true))) { _ in }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Let a second HLS GOP finish. An incomplete first GOP does not yet
        // form a seekable packet-cache range even though its stills are usable.
        do { try spin(until: { player.watchedFrameTimes.count >= 3 }, seconds: 30, label: "watched samples") }
        catch {
            print("FAIL watched frames=\(player.watchedFrameTimes), position=\(player.engine.double("time-pos")), pause=\(player.engine.flag("pause")), seeking=\(player.engine.flag("seeking")), awaiting=\(player.engine.awaitingDecodedFrame), video=\(player.engine.integer("video-params/w")) error=\(player.engine.lastError ?? "none")")
            exit(1)
        }
        try player.engine.execute(.pause(true))
        let times = player.watchedFrameTimes, position = player.engine.double("time-pos")
        print("WATCHED times=\(times) position=\(position)"); fflush(stdout)
        print("CACHE before offline=\(player.engine.string("demuxer-cache-state"))"); fflush(stdout)
        precondition(times.allSatisfy { $0 <= position } && times[1] - times[0] >= 5)
        let restart = player.engine.playbackRestartGeneration
        precondition(player.engine.string("cache") == "yes")
        precondition(player.engine.string("cache-on-disk") == "no")
        precondition(player.engine.integer("demuxer-max-bytes") == 134217728)
        precondition(player.engine.integer("demuxer-max-back-bytes") == 536870912)
        _ = try Data(contentsOf: base.appendingPathComponent("offline"))
        var poster: Result<Any, Error>?
        let output = root.appendingPathComponent("watched.png")
        try player.beginPosterCapture(to: output, title: "自有网络测试 · 已看画面") { poster = $0 }
        try spin(until: { poster != nil }, seconds: 4, label: "offline poster")
        let fields = try poster!.get() as! [String: Any]
        print("POSTER frames=\(fields["frames"] ?? 0)"); fflush(stdout)
        precondition(fields["frames"] as? Int == times.count)
        precondition(player.engine.playbackRestartGeneration == restart, "poster must never seek")
        precondition(abs(player.engine.double("time-pos") - position) < 0.25 && player.engine.flag("pause"))
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == 1200 && image.height == 1800)
        let qr = VNDetectBarcodesRequest(); qr.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([qr])
        precondition(qr.results?.contains { $0.payloadStringValue == "https://github.com/dashizhihuan2018-source/AIPlayer" } == true)
        if CommandLine.arguments.count > 1 { try Data(contentsOf: output).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        // Already-watched video packets, not just stills, must remain usable
        // when the controlled origin refuses every request.
        try player.engine.execute(.seek(times[0]))
        do { try spin(until: { player.handle(.getState) { _ in }; return !player.engine.awaitingDecodedFrame && !player.engine.flag("seeking") }, seconds: 4, label: "offline backseek") }
        catch {
            print("BACKSEEK position=\(player.engine.double("time-pos")) seeking=\(player.engine.flag("seeking")) awaiting=\(player.engine.awaitingDecodedFrame) cache=\(player.engine.string("demuxer-cache-state"))")
            fflush(stdout)
            throw error
        }
        precondition(abs(player.engine.double("time-pos") - times[0]) < 1)
        player.handle(.engine(.stop)) { _ in }
        precondition(player.watchedFrameTimes.isEmpty)
        print("Watched online cache: three actual watched frames; offline poster/QR under four seconds, zero poster seeks; offline backseek; stop isolation PASS")
    }
    private static func spin(until condition: () -> Bool, seconds: Double, label: String) throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard condition() else { throw MediaToolError.message("watched network test deadline exceeded: " + label) }
    }
}
