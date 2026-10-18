import AppKit
import Foundation
import WebKit

@main struct NativeEngineRouteTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: NativeEngineRouteTests <owned-video>") }
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-route-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView = container
        let web = WKWebView(frame: container.bounds)
        container.addSubview(web)
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: support)
        defer { player.shutdown() }
        try player.engine.execute(.mute(true))
        try player.engine.execute(.pause(true))
        var loaded: Result<Any, Error>?
        player.handle(.loadURL(URL(fileURLWithPath: CommandLine.arguments[1]), position: 2)) { loaded = $0 }
        let deadline = Date().addingTimeInterval(20)
        while loaded == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let loaded else { fatalError("load timeout") }
        _ = try loaded.get()
        let cases: [(ValidatedEngineCommand, String, Double)] = [
            (.rotation(90), "video-rotate", 90), (.rotation(0), "video-rotate", 0),
            (.brightness(17), "brightness", 17), (.contrast(-12), "contrast", -12),
            (.saturation(23), "saturation", 23), (.gamma(8), "gamma", 8), (.hue(-5), "hue", -5),
            (.volume(72), "volume", 72), (.speed(1.5), "speed", 1.5),
            (.audioDelay(0.25), "audio-delay", 0.25), (.subtitleDelay(-0.5), "sub-delay", -0.5)
        ]
        var failures = 0
        for (command, property, expected) in cases {
            do {
                try player.engine.execute(command)
                let actual = player.engine.double(property, fallback: -999)
                if abs(actual - expected) > 0.001 { print("FAIL \(property): read \(actual), expected \(expected)"); failures += 1 }
                else { print("PASS \(property) = \(actual)") }
            } catch { print("FAIL \(property): \(error.localizedDescription)"); failures += 1 }
        }
        for value in ["default", "cover", "fill", "16:9", "4:3"] {
            do { try player.engine.execute(.aspect(value)); print("PASS aspect \(value)") }
            catch { print("FAIL aspect \(value): \(error.localizedDescription)"); failures += 1 }
        }
        for command in [ValidatedEngineCommand.deinterlace(true), .deinterlace(false), .hwdec(false), .hwdec(true), .loop(true), .loop(false), .frameStep, .frameBackStep] {
            do { try player.engine.execute(command); print("PASS \(command)") }
            catch { print("FAIL \(command): \(error.localizedDescription)"); failures += 1 }
        }
        for command in [ValidatedEngineCommand.rotation(0), .brightness(0), .contrast(0), .saturation(0), .gamma(0), .hue(0), .speed(1), .pause(true), .seek(2)] { try player.engine.execute(command) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        player.handle(.engine(.seek(10))) { _ in }
        var ocr: Result<Any, Error>?
        player.handle(.ocr) { ocr = $0 }
        let captureDeadline = Date().addingTimeInterval(10)
        while ocr == nil && Date() < captureDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if let ocr, let value = try ocr.get() as? [String: Any], let text = value["text"] as? String, text.contains("00:00:10") { print("PASS immediate seek → OCR captures decoded target frame") }
        else { print("FAIL immediate seek → OCR captured an old frame"); failures += 1 }
        guard failures == 0 else { print("Native engine route failures: \(failures)"); exit(1) }
        print("Native engine property routes and actual readback PASS")
    }
}
