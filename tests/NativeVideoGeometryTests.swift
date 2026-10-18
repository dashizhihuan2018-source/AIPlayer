import AppKit
import WebKit

@main struct NativeVideoGeometryTests {
    static func main() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window.contentView = container
        let webView = WKWebView(frame: container.bounds)
        container.addSubview(webView)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-geometry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let player = try NativePlayerController(webView: webView, window: window, container: container, supportDirectory: support)
        var failures = 0
        // Web controls must remain visible over the native video surface.
        // Pointer pass-through alone cannot fix a reversed sibling paint order.
        if let videoIndex = container.subviews.firstIndex(of: player.videoView),
           let webIndex = container.subviews.firstIndex(of: webView), videoIndex < webIndex {
            print("PASS native video is below the HTML control surface")
        } else {
            print("FAIL native video must be below the HTML control surface")
            failures += 1
        }
        if (webView.value(forKey: "drawsBackground") as? Bool) == false {
            print("PASS HTML control surface permits transparent native video composition")
        } else {
            print("FAIL HTML control surface must not paint an opaque WebKit background")
            failures += 1
        }
        for (name, rectangle) in [
            ("normal", VideoRectangle(x: 93, y: 79, width: 1000, height: 536, visible: true)),
            ("fullscreen control safe area", VideoRectangle(x: 0, y: 0, width: 1216, height: 648, visible: true)),
        ] {
            player.handle(.setVideoRect(rectangle)) { _ in }
            let expected = NSRect(x: rectangle.x, y: 800 - rectangle.y - rectangle.height,
                                  width: rectangle.width, height: rectangle.height).integral
            let actual = player.videoView.frame
            if actual != expected {
                print("FAIL \(name): WKWebView.isFlipped=\(webView.isFlipped), expected=\(expected), actual=\(actual)")
                failures += 1
            } else { print("PASS \(name): \(actual)") }
        }
        // A web view can have an inset frame; DOM coordinates are local to it.
        webView.frame = NSRect(x: 12, y: 24, width: 1200, height: 700)
        player.handle(.setVideoRect(VideoRectangle(x: 20, y: 30, width: 600, height: 400, visible: true))) { _ in }
        if player.videoView.frame != NSRect(x: 32, y: 294, width: 600, height: 400) {
            print("FAIL inset web view conversion: \(player.videoView.frame)")
            failures += 1
        } else { print("PASS inset web view conversion") }
        player.handle(.setVideoRect(VideoRectangle(x: 1100, y: 600, width: 300, height: 300, visible: true))) { _ in }
        if player.videoView.frame != NSRect(x: 1112, y: 24, width: 100, height: 100) {
            print("FAIL viewport clipping: \(player.videoView.frame)")
            failures += 1
        } else { print("PASS viewport clipping") }
        // Native surfaces outlive a web document. Leaving its owner must hide
        // it synchronously, even if React's asynchronous cleanup is discarded.
        try player.engine.execute(.pause(false))
        player.videoView.isHidden = false
        player.pageWillNavigate()
        if !player.videoView.isHidden || !player.engine.flag("pause") {
            print("FAIL full navigation must hide and pause the previous native surface")
            failures += 1
        } else { print("PASS full navigation hides and pauses native surface") }
        try player.engine.execute(.pause(false))
        player.videoView.isHidden = false
        player.handle(.mediaNotReady) { _ in }
        if !player.videoView.isHidden || !player.engine.flag("pause") {
            print("FAIL SPA owner unmount must hide and pause the previous native surface")
            failures += 1
        } else { print("PASS SPA unmount hides and pauses native surface") }
        player.shutdown()
        if failures > 0 { exit(1) }
    }
}
