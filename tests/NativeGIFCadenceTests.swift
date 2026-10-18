import AppKit
import Foundation
import ImageIO
import WebKit
import CryptoKit

@main struct NativeGIFCadenceTests {
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiplayer-gif-cadence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentView!.bounds); window.contentView = container
        let web = WKWebView(frame: container.bounds); container.addSubview(web)
        let store = NativeToolOutputStore(homeDirectory: root.appendingPathComponent("home"))
        let player = try NativePlayerController(webView: web, window: window, container: container, supportDirectory: root, toolPresentation: { _ in preconditionFailure("GIF opened a window") }, toolOutputStore: store)
        defer { player.shutdown() }
        func call(_ request: ValidatedNativeRequest) throws -> [String: Any] {
            var result: Result<Any, Error>?
            player.handle(request) { result = $0 }
            let deadline = Date().addingTimeInterval(60)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            return try result!.get() as! [String: Any]
        }
        try player.engine.execute(.pause(true)); try player.engine.execute(.mute(true))
        _ = try call(.loadURL(URL(fileURLWithPath: CommandLine.arguments[1]), position: 0))
        _ = try call(.setVideoRect(VideoRectangle(x: 0, y: 0, width: 960, height: 540, visible: true)))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var beats = 0
        var lastBeat = Date(), longestGap = 0.0
        let heartbeat = Timer(timeInterval: 0.01, repeats: true) { _ in
            longestGap = max(longestGap, Date().timeIntervalSince(lastBeat)); lastBeat = Date(); beats += 1
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate() }
        for maximumWidth in [640, 3840] {
        for speed in [0.5, 1.0, 2.0] {
            try player.engine.execute(.seek(0)); try player.engine.execute(.speed(speed)); try player.engine.execute(.pause(false))
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let baselineBeat = beats
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            print("BASELINE speed=\(speed) mainBeats=\(beats - baselineBeat)"); fflush(stdout)
            let position = player.engine.double("time-pos"), startBeat = beats
            longestGap = 0; lastBeat = Date()
            _ = try call(.gifStart(fps: 20, maximumWidth: maximumWidth))
            let start = Date()
            RunLoop.main.run(until: start.addingTimeInterval(1.2))
            let beforeStop = Date().timeIntervalSince(start)
            let progress = player.engine.double("time-pos") - position
            let pulseCount = beats - startBeat
            let gap = longestGap
            let saved = try call(.gifStop)
            let count = saved["frames"] as! Int
            let duration = saved["duration"] as! Double
            print("CADENCE width=\(maximumWidth) speed=\(speed) frames=\(count) duration=\(duration) mainBeats=\(pulseCount) maxMainGap=\(gap) mediaProgress=\(progress)")
            fflush(stdout)
            // Requested output cadence is independent of unique source frames.
            // Require >=14 sampled fps, with no one-second holds, even at UHD.
            let minimum = 17
            guard count >= minimum else { throw MediaToolError.message("recording collapsed to \(count) snapshots; expected at least \(minimum)") }
            // A 10ms heartbeat isn't a promise of a 100Hz display/UI. Keep the
            // original responsiveness floor and additionally reject long stalls.
            precondition(pulseCount >= 50 && gap < 0.15, "GIF snapshot/cache work must not block the main/render loop")
            precondition(abs(progress / beforeStop - speed) < 0.4, "recording must retain the selected playback speed")
            let file = store.directory(for: .gif).appendingPathComponent(saved["name"] as! String)
            let source = CGImageSourceCreateWithURL(file as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let sourceWidth = Int(player.engine.double("video-params/w"))
            precondition(image.width == min(maximumWidth, sourceWidth), "cadence must retain the requested source resolution, not silently downscale")
            var delays = [Double]()
            var frameDigests = Set<String>()
            for index in 0..<CGImageSourceGetCount(source) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)! as NSDictionary
                let gif = properties[kCGImagePropertyGIFDictionary] as! NSDictionary
                delays.append((gif[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue)
                try autoreleasepool {
                    let image = CGImageSourceCreateImageAtIndex(source, index, nil)!
                    let thumbnail = try NativeMediaTools.resized(image, maximumWidth: 160)
                    frameDigests.insert(SHA256.hash(data: thumbnail.dataProvider!.data! as Data).description)
                }
            }
            precondition(frameDigests.count >= 3, "a high sample count must not hide a frozen/repeated source frame")
            print("GIF UNIQUE width=\(maximumWidth) speed=\(speed) frames=\(frameDigests.count)"); fflush(stdout)
            precondition(delays.filter { $0 > 0.15 }.count <= 1, "output must not have repeated one-second holds")
            precondition(abs(delays.reduce(0,+) - duration) < 0.08, "GIF wall time must not change when playback speed changes")
        }
        }
        try player.engine.execute(.seek(0)); try player.engine.execute(.speed(0.5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let baselineFirst = player.engine.double("time-pos")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let baselineMiddle = player.engine.double("time-pos")
        try player.engine.execute(.speed(2))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let baselineLast = player.engine.double("time-pos")
        print("SPEED BASELINE first=\(baselineFirst) middle=\(baselineMiddle) last=\(baselineLast)"); fflush(stdout)
        try player.engine.execute(.seek(0)); try player.engine.execute(.speed(0.5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        _ = try call(.gifStart(fps: 20, maximumWidth: 640))
        let first = player.engine.double("time-pos")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let middle = player.engine.double("time-pos")
        try player.engine.execute(.speed(2))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let last = player.engine.double("time-pos")
        let changed = try call(.gifStop)
        print("SPEED CHANGE first=\(first) middle=\(middle) last=\(last) frames=\(changed["frames"]!) duration=\(changed["duration"]!)"); fflush(stdout)
        // Audio-bearing media has a short libmpv tempo-filter settling period
        // on a rate change (also present without recording). Compare the same
        // source's real baseline rather than promising instantaneous clock jumps.
        guard abs(baselineMiddle - baselineFirst - 0.6) < 0.25,
              baselineLast - baselineMiddle > 1.5,
              abs((middle - first) - (baselineMiddle - baselineFirst)) < 0.15,
              abs((last - middle) - (baselineLast - baselineMiddle)) < 0.15,
              abs(player.engine.double("speed") - 2) < 0.001 else {
            throw MediaToolError.message("mid-recording speed changes diverged from actual source playback")
        }
        guard (changed["frames"] as! Int) >= 34 && abs((changed["duration"] as! Double) - 2.4) < 0.25 else {
            throw MediaToolError.message("mid-recording speed change lost cadence or wall duration")
        }
        print("Native GIF displayed-source cadence, UI responsiveness, 0.5/1/2x and mid-capture speed change PASS")
    }
}
