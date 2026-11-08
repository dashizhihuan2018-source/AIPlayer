import AppKit
import WebKit

@main struct NativeAutoplayTests {
    static func main() throws {
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-autoplay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds); window.contentView = container
        let web = WKWebView(frame: container.bounds); container.addSubview(web)
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: root)
        defer { player.shutdown() }
        func state() -> [String: Any] {
            var result: [String: Any] = [:]
            player.handle(.getState) { result = (try? $0.get()) as? [String: Any] ?? [:] }
            return result
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "AutoplayRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func spin(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        func load(_ position: Double) throws -> [String: Any] {
            var reply: Result<Any, Error>?
            player.handle(.loadURL(fixture, position: position)) { reply = $0 }
            try require(spin { reply != nil }, "load did not complete")
            return try reply!.get() as! [String: Any]
        }
        try player.engine.execute(.mute(true))
        try player.engine.execute(.pause(false))
        _ = try load(0)
        // keep-open=yes pauses mpv at EOF. Every following episode must undo it.
        for episode in 2...4 {
            let duration = player.engine.double("duration")
            try require(duration >= 3, "fixture must be at least three seconds long")
            try player.engine.execute(.seek(duration - 0.4))
            try require(spin { state()["ended"] as? Bool == true }, "previous episode never reached EOF")
            try require(player.engine.flag("pause"), "fixture did not reproduce keep-open EOF pause")
            let loaded = try load(0)
            try require(loaded["paused"] as? Bool == false, "episode \(episode) loaded paused instead of autoplaying")
            try require(spin { state()["time"] as? Double ?? 0 > 0.2 }, "episode \(episode) clock did not advance")
        }
        player.pageWillNavigate()
        try require(player.engine.flag("pause"), "navigation must still pause the old owner")
        let restored = try load(2)
        try require(restored["paused"] as? Bool == false, "navigation pause leaked into the new episode")
        try require(spin { state()["time"] as? Double ?? 0 > 2.2 }, "restored episode did not play")
        player.handle(.engine(.pause(true))) { _ in }
        let position = player.engine.double("time-pos")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try require(player.engine.flag("pause") && abs(player.engine.double("time-pos") - position) < 0.1, "manual pause must remain effective after load")
        print("Native autoplay: three EOF transitions, navigation/resume, advancing clock and manual pause PASS")
    }
}
