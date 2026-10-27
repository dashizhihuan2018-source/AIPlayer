import AppKit
import Foundation
import WebKit

@main struct NativePlaybackPowerTests {
    static func main() throws {
        _ = NSApplication.shared
        let oldPreference = UserDefaults.standard.object(forKey: "AIPlayer.keepAwake")
        defer {
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: "AIPlayer.keepAwake") }
            else { UserDefaults.standard.removeObject(forKey: "AIPlayer.keepAwake") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-power-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        func spin(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(condition(), "playback transition timeout")
        }
        player.handle(.keepAwake(true)) { _ in }
        precondition(state()["displayAwake"] as? Bool == false, "idle must not inhibit sleep")
        try player.engine.execute(.mute(true))
        try player.engine.execute(.pause(false))
        var loaded = false
        player.handle(.loadURL(URL(fileURLWithPath: CommandLine.arguments[1]), position: 0)) { result in
            loaded = (try? result.get()) != nil
        }
        spin { loaded && state()["displayAwake"] as? Bool == true }
        player.handle(.engine(.pause(true))) { _ in }
        precondition(state()["displayAwake"] as? Bool == false, "pause must release display assertion")
        player.handle(.engine(.pause(false))) { _ in }
        spin { state()["displayAwake"] as? Bool == true }
        player.handle(.keepAwake(false)) { _ in }
        precondition(state()["displayAwake"] as? Bool == false, "toggle must release immediately")
        player.handle(.keepAwake(true)) { _ in }
        precondition(state()["displayAwake"] as? Bool == true)
        player.handle(.engine(.seek(23))) { _ in }
        spin { state()["ended"] as? Bool == true }
        precondition(state()["displayAwake"] as? Bool == false, "EOF must release display assertion")
        player.handle(.engine(.stop)) { _ in }
        precondition(state()["displayAwake"] as? Bool == false, "stop must release display assertion")
        player.shutdown()
        print("Native power lifecycle: idle/play/pause/resume/toggle/EOF/stop/shutdown PASS")
    }
}
